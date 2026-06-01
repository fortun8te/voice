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

enum CardShape {
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
    /// Which main tab is selected: "Dictations" or "Meetings".
    @State private var selectedTab: BigMenuTab = .dictations
    /// At most ONE row is expanded at a time. nil = nothing expanded.
    @State private var expandedID: String? = nil
    /// Transient "Copied" indicator. Maps row id → expiration token. Each
    /// copy increments to keep timing accurate when re-copied quickly.
    @State private var copiedToken: [String: Int] = [:]
    /// At most ONE meeting row is expanded at a time.
    @State private var meetingExpandedID: UUID? = nil
    /// Scroll target for jumping to a specific meeting (set when the user
    /// clicks a meeting title in the calendar popover).
    @State private var meetingsScrollTarget: UUID? = nil
    /// List vs. month-grid calendar view for the Meetings tab.
    @State private var meetingsViewMode: MeetingsViewMode = .list
    /// Free-text search across meeting titles + transcript content. Empty
    /// string shows the unfiltered list.
    @State private var meetingSearchQuery: String = ""
    /// True while a file-import is in flight so the button shows progress
    /// and we don't double-fire on rapid clicks.
    @State private var meetingImportInProgress: Bool = false

    // MARK: - Permissions integration
    @State private var permissions = PermissionsService.shared
    @State private var showPermissionsSheet = false

    /// True when the list/calendar body is scrolled past the top. Used to
    /// thicken the top toolbar's backdrop blur so it visually separates from
    /// content sliding under it. Updated by `.onScrollGeometryChange` on the
    /// active scroll view (dictations + meetings list).
    @State private var isToolbarScrolled: Bool = false
    /// Matched-geometry namespace for the sliding selection indicator on the
    /// primary + secondary segmented controls in the top toolbar. Two distinct
    /// IDs ("primarySegment", "secondarySegment") so they slide independently.
    @Namespace private var toolbarSelectionNS

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

    /// Filter the grouped meetings by the search query (title + transcript).
    /// Empty query returns everything. Query matches are case-insensitive
    /// substring matches against title and segment text.
    private var filteredMeetingGroups: [(day: Date, items: [Meeting])] {
        let q = meetingSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return groupedMeetings }
        var out: [(Date, [Meeting])] = []
        for group in groupedMeetings {
            let hits = group.items.filter { m in
                if m.title.lowercased().contains(q) { return true }
                for seg in m.segments {
                    if seg.text.lowercased().contains(q) { return true }
                }
                if let overview = m.summary?.overview.lowercased(), overview.contains(q) { return true }
                return false
            }
            if !hits.isEmpty {
                out.append((group.day, hits))
            }
        }
        return out
    }

    /// Search + import toolbar at the top of the Meetings tab.
    @ViewBuilder
    private var meetingsToolbar: some View {
        HStack(spacing: Sp.sm) {
            // Search field with magnifying glass + clear button when text is present.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search meetings, transcripts…", text: $meetingSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.bodySmall)
                if !meetingSearchQuery.isEmpty {
                    Button {
                        meetingSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Sp.sm)
            .padding(.vertical, 6)
            .glassEffect(
                .regular.tint(Color.primary.opacity(0.06)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            // Import audio file → adds as a meeting + transcribes.
            Button(action: importMeetingAudio) {
                HStack(spacing: 5) {
                    Image(systemName: meetingImportInProgress ? "ellipsis" : "square.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                    Text(meetingImportInProgress ? "Importing…" : "Import")
                        .font(.bodySmall.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.glass)
            .tint(Color.accentColor.opacity(0.16))
            .disabled(meetingImportInProgress)
            .help("Import an audio file (m4a, mp3, wav, caf) as a meeting")
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.sm)
    }

    /// Single-row top toolbar combining the primary tab picker
    /// (Dictations / Meetings) and — only when Meetings is active — the
    /// secondary List / Calendar view-mode picker. The two pickers used to
    /// be stacked, which wasted vertical space and read as two unrelated
    /// controls; merging them into one 36pt-tall row reads as one toolbar.
    ///
    /// The secondary picker animates in from the trailing edge with a
    /// move+fade transition so the appearance feels intentional rather than
    /// a layout jump. Selection indicators on each segmented control use a
    /// `matchedGeometryEffect` so the highlight slides between segments
    /// instead of cross-fading.
    @ViewBuilder
    private var topToolbar: some View {
        HStack(spacing: Sp.md) {
            // Primary: Dictations / Meetings.
            SegmentedGlassPicker(
                selection: $selectedTab,
                options: BigMenuTab.allCases,
                label: \.label,
                isPrimary: true,
                namespace: toolbarSelectionNS,
                geometryID: "primarySegment"
            )

            Spacer(minLength: Sp.sm)

            // Secondary: List / Calendar — only visible on the Meetings tab.
            // Slides in from the trailing edge so the appearance reads as a
            // contextual extension of the primary tab, not a separate row.
            if selectedTab == .meetings {
                SegmentedGlassPicker(
                    selection: $meetingsViewMode,
                    options: MeetingsViewMode.allCases,
                    label: \.label,
                    isPrimary: false,
                    namespace: toolbarSelectionNS,
                    geometryID: "secondarySegment"
                )
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .padding(.horizontal, Sp.lg)
        .padding(.vertical, Sp.sm)
        // Subtle backdrop that thickens once the body scrolls under it. The
        // base layer stays nearly transparent so the toolbar feels weightless
        // when the list is at rest; once content slides beneath, a thin
        // material + hairline divider appear so the toolbar reads as a fixed
        // chrome layer rather than floating type on top of moving content.
        .background(alignment: .bottom) {
            Rectangle()
                .fill(.thinMaterial)
                .opacity(isToolbarScrolled ? 1.0 : 0.0)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                        .opacity(isToolbarScrolled ? 1.0 : 0.0)
                }
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.18), value: isToolbarScrolled)
        }
        // Animate insertion/removal of the secondary picker AND the matched-
        // geometry selection indicators inside both pickers. Spring keeps the
        // motion playful but quick — under 220ms perceived.
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: selectedTab)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: meetingsViewMode)
    }

    /// Open an NSOpenPanel for an audio file, import it via the recovery
    /// service, then trigger transcription. Runs entirely on the app delegate
    /// — UI only owns progress state.
    private func importMeetingAudio() {
        guard !meetingImportInProgress else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .mpeg4Audio, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an audio file to transcribe as a meeting."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        meetingImportInProgress = true
        Task { @MainActor in
            defer { meetingImportInProgress = false }
            guard let app = NSApp.delegate as? AppDelegate else { return }
            let imported = await app.meetingRecovery.importAudioFile(url)
            guard let meeting = imported else {
                NotificationCenter.default.post(
                    name: .voiceError,
                    object: nil,
                    userInfo: ["message": "Couldn't import that audio file. Try a different format (m4a/mp3/wav/caf)."]
                )
                return
            }
            app.reloadMeetingsFromDisk()
            // Kick off transcription via the same notification path the
            // BigMenu "Transcribe now" button uses.
            NotificationCenter.default.post(
                name: .voiceTranscribeMeetingRequested,
                object: nil,
                userInfo: ["meetingId": meeting.id.uuidString]
            )
        }
    }

    @ViewBuilder
    private var noSearchResultsState: some View {
        VStack(spacing: Sp.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.quaternary)
            Text("No matches")
                .font(.bodyMedium)
                .foregroundStyle(.primary)
            Text("Try a different query.")
                .font(.bodySmall)
                .foregroundStyle(.tertiary)
        }
    }

    /// Same grouping as `grouped`, but for meetings. Newest day first.
    /// Hard filter: anything under 3 minutes OR kind != .meeting never
    /// shows in the meetings tab — those are dictations / aborted sessions.
    private var groupedMeetings: [(day: Date, items: [Meeting])] {
        let cal = Calendar.current
        var buckets: [(Date, [Meeting])] = []
        let real = recordingState.meetings.filter { m in
            m.kind == .meeting && m.duration >= 300
        }
        for m in real {
            let day = cal.startOfDay(for: m.date)
            if let idx = buckets.firstIndex(where: { $0.0 == day }) {
                buckets[idx].1.append(m)
            } else {
                buckets.append((day, [m]))
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

                // Single-row top toolbar. Primary picker on the left
                // (Dictations / Meetings), secondary on the right (List /
                // Calendar — only when Meetings is selected). 36pt-tall
                // chrome row instead of two stacked pickers.
                topToolbar

                switch selectedTab {
                case .dictations:
                    if recents.isEmpty {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 0) {
                                LearnedWordsCard()
                                    .padding(.horizontal, Sp.lg)
                                    .padding(.top, Sp.md)
                                emptyState
                                    .frame(maxWidth: .infinity, minHeight: 200)
                            }
                        }
                        .background(DictationListBackground())
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                                LearnedWordsCard()
                                    .padding(.horizontal, Sp.lg)
                                    .padding(.top, Sp.md)
                                    .padding(.bottom, Sp.sm)
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
                        // Track scroll offset so the top toolbar's backdrop
                        // thickens once content slides beneath it (creates a
                        // subtle "elevated chrome" effect tied to interaction).
                        .onScrollGeometryChange(for: Bool.self) { geo in
                            geo.contentOffset.y > 2
                        } action: { _, scrolled in
                            isToolbarScrolled = scrolled
                        }
                        // Subtle "content area" surface — slightly darker than the
                        // window chrome so the list reads as a distinct container
                        // without needing a heavy frame. Corner radius 0 because
                        // the area extends to the bottom of the window and would
                        // look clipped if rounded.
                        .background(DictationListBackground())
                    }

                case .meetings:
                    // Search + import toolbar above the list. Always visible
                    // — searching filters the displayed groups in real time.
                    // (The List / Calendar segmented control has moved into
                    // the unified `topToolbar` above.)
                    meetingsToolbar

                    switch meetingsViewMode {
                    case .list:
                        // Priority order for the meetings tab body, when the
                        // user is on .list mode:
                        //
                        //   1. A meeting is actively capturing → always show
                        //      the list so the LiveMeetingRow is visible. This
                        //      preempts skeleton/empty/error states — the
                        //      capture is the user's primary feedback signal.
                        //   2. Initial first-time load (no rows yet) → skeleton.
                        //   3. Read threw → error view with Retry. (Skipped
                        //      when there's a stale list to fall back to.)
                        //   4. Read succeeded, no matches for the search → noResults.
                        //   5. Read succeeded, DB empty → empty state.
                        //   6. Otherwise → the list.
                        //
                        // Reloads after the first successful load do NOT flash
                        // back to the skeleton — keeping the stale list on
                        // screen during a quick reread feels less jumpy than
                        // a constant skeleton-then-list swap.
                        if recordingState.isCapturingMeeting {
                            meetingsListBody
                        } else if recordingState.meetings.isEmpty,
                                  case .initial = recordingState.meetingsLoadState {
                            meetingsLoadingState
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(DictationListBackground())
                        } else if recordingState.meetings.isEmpty,
                                  case .loading = recordingState.meetingsLoadState {
                            meetingsLoadingState
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(DictationListBackground())
                        } else if recordingState.meetings.isEmpty,
                                  case .error(let reason) = recordingState.meetingsLoadState {
                            meetingsErrorState(reason: reason)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(DictationListBackground())
                        } else if filteredMeetingGroups.isEmpty {
                            if meetingSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                                emptyMeetingsState
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(DictationListBackground())
                            } else {
                                noSearchResultsState
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(DictationListBackground())
                            }
                        } else {
                            meetingsListBody
                        }

                    case .calendar:
                        // Real meetings only — drop dictations (kind != .meeting)
                        // so the calendar reflects what users mentally call
                        // "meetings."
                        let realMeetings = recordingState.meetings.filter { $0.kind == .meeting }
                        MeetingCalendarView(meetings: realMeetings) { id in
                            // Selecting a meeting in the calendar popover jumps
                            // back to the list, expands the row, and scrolls.
                            meetingsViewMode = .list
                            meetingExpandedID = id
                            // Defer the scroll one run-loop turn so ScrollViewReader
                            // has mounted by the time the target changes.
                            Task { @MainActor in
                                await Task.yield()
                                meetingsScrollTarget = id
                            }
                        }
                        .background(DictationListBackground())
                    }

                case .video:
                    VideoTranscriptionView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DictationListBackground())
                }

                Divider()
                HStack {
                    // Footer: utility buttons, plain text + icon. The previous
                    // dual filled chips fought each other visually — one button
                    // backed surface, one icon-only, both with chip backgrounds.
                    // Now: gear icon as a borderless icon button, Quit as plain
                    // text. Hover state alone communicates interactivity.
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings")

                    Spacer()

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Text("Quit Voice")
                            .font(.bodySmall)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Sp.sm)
                            .padding(.vertical, Sp.xs)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Sp.lg)
                .padding(.vertical, Sp.md)
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 500, idealHeight: 620)
        // Background dim + blur when the Settings sheet is open. SwiftUI's
        // default sheet on macOS does not dim the host window — this pulls
        // focus onto the sheet so the BigMenu visually recedes.
        .blur(radius: showSettings ? 24 : 0)
        .overlay {
            if showSettings {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showSettings)
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
            // Pending meeting ID from a system notification click — open with
            // the Meetings tab pre-selected, the row expanded, and scrolled
            // into view. The static is cleared so it doesn't re-fire on tab
            // switches later.
            consumePendingNotificationMeetingID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceOpenMeetingFromNotification)) { note in
            // Window was already open when the notification was tapped — still
            // route to the right row.
            if let idStr = note.userInfo?["meetingId"] as? String,
               let uuid = UUID(uuidString: idStr) {
                AppDelegate.pendingMeetingIDFromNotification = nil
                selectedTab = .meetings
                meetingExpandedID = uuid
                meetingsScrollTarget = uuid
            }
        }
        .onChange(of: recordingState.recentDictationsTick) { _, _ in
            // Auto-expand the new latest entry so the user immediately sees
            // the per-model breakdown for the fresh result.
            if let newest = recents.first {
                expandedID = newest.id
            }
        }
        .onChange(of: recordingState.isCapturingMeeting) { _, capturing in
            // Auto-switch to the Meetings tab the moment a capture session starts
            // so the user immediately sees the live "Recording now" row.
            if capturing { selectedTab = .meetings }
        }
        .onChange(of: selectedTab) { _, _ in
            // Each ScrollView mounts fresh when tabs swap, so re-baseline the
            // toolbar's "scrolled" flag — otherwise the elevated chrome can
            // stick on after switching from a scrolled list to an empty one.
            isToolbarScrolled = false
        }
        .onChange(of: meetingsViewMode) { _, _ in
            isToolbarScrolled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceOpenBigMenuSettings)) { _ in
            showSettings = true
        }
    }

    // MARK: - Stats row

    @ViewBuilder
    private var statsRow: some View {
        let stats = computeStats()
        HStack(spacing: Sp.lg) {
            StatCard(
                icon: "doc.text",
                value: formatLargeNumber(stats.totalWords),
                label: "Total words"
            )
            StatCard(
                icon: "stopwatch",
                value: speakingTimeString(stats.speakingSeconds),
                label: "Speaking time"
            )
            StatCard(
                icon: "waveform",
                value: stats.avgPace > 0 ? "\(stats.avgPace) wpm" : "—",
                label: "Avg pace"
            )
        }
    }

    /// Format seconds into "21h 50m", "47m", "< 1m".
    private func speakingTimeString(_ seconds: Int) -> String {
        if seconds < 60  { return "< 1m" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// Format large integers with comma separators: 7698 → "7,698".
    private func formatLargeNumber(_ n: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Compute headline stats from lifetime RecordingState counters.
    /// Words + sessions + duration come from UserDefaults-persisted lifetime
    /// totals (updated after every dictation). Avg pace uses lifetime figures
    /// so it stabilises quickly and doesn't swing wildly on a slow day.
    private func computeStats() -> (totalWords: Int, speakingSeconds: Int, avgPace: Int) {
        let words   = recordingState.lifetimeWords
        let seconds = recordingState.lifetimeDurationSeconds
        let pace    = seconds > 0 ? Int((Double(words) * 60.0) / Double(seconds)) : 0
        return (words, seconds, pace)
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
            // Asymmetric padding: lg above to clearly separate day groups,
            // sm below so the header reads as belonging to the rows it labels.
            .padding(.top, Sp.lg)
            .padding(.bottom, Sp.sm)
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
    /// If AppDelegate stashed a meeting ID from a "Transcript ready" notification
    /// click, consume it now — switch to the Meetings tab, expand that row, and
    /// queue a scroll so it lands in view. One-shot: the static is cleared.
    private func consumePendingNotificationMeetingID() {
        guard let idStr = AppDelegate.pendingMeetingIDFromNotification,
              let uuid = UUID(uuidString: idStr) else { return }
        AppDelegate.pendingMeetingIDFromNotification = nil
        selectedTab = .meetings
        meetingExpandedID = uuid
        // Defer the scroll one run-loop turn so the LazyVStack has time to
        // materialize the row before ScrollViewReader tries to scroll to it.
        Task { @MainActor in
            await Task.yield()
            meetingsScrollTarget = uuid
        }
    }

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
        VStack(spacing: Sp.lg) {
            // Icon recedes to quaternary so the headline is the focal point.
            // 24pt instead of 28pt to match the calmer overall hierarchy.
            Image(systemName: "waveform.badge.microphone")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text("No dictations yet")
                .font(.bodyMedium)
                .foregroundStyle(.primary)
            Text("Hold fn anywhere and start speaking.")
                .font(.bodySmall)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Sp.xl)
        }
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

    // MARK: - Meetings list body
    //
    // Extracted so the .list branch in the body can swap freely between
    // states (skeleton / error / empty / list) without duplicating the
    // ScrollViewReader scaffolding.

    @ViewBuilder
    private var meetingsListBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if recordingState.isCapturingMeeting {
                        LiveMeetingRow(
                            transcript: recordingState.meetingLiveTranscript,
                            durationSeconds: recordingState.meetingDurationSeconds,
                            sourceBundleID: recordingState.meetingSourceBundleID,
                            participantCount: recordingState.meetingParticipantNames.count
                        )
                        Divider()
                    }
                    ForEach(filteredMeetingGroups, id: \.day) { group in
                        dateHeader(group.day)
                        ForEach(group.items) { meeting in
                            MeetingRow(meeting: meeting, expandedID: $meetingExpandedID)
                                .id(meeting.id)
                        }
                    }
                }
                .padding(.bottom, Sp.md)
            }
            // Track scroll offset for the top toolbar's
            // elevated-chrome backdrop blur effect.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y > 2
            } action: { _, scrolled in
                isToolbarScrolled = scrolled
            }
            .background(DictationListBackground())
            .onChange(of: meetingsScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                // One-shot — clear so the same target can be
                // re-requested later.
                meetingsScrollTarget = nil
            }
        }
    }

    // MARK: - Meetings empty state
    //
    // Family-matched with the dictations empty state (same VStack rhythm,
    // same .quaternary-tone illustration, same body-vs-bodySmall hierarchy)
    // but turns the volume up:
    //   • Illustration is 60pt instead of 24pt — there's more dead space to
    //     fill, and waveform.path reads as a meeting-product motif (not a
    //     mic icon, which would feel redundant against the dictation tab).
    //   • Adds a primary action button so the meetings tab is never a
    //     dead-end for new users — auto-detect is calm, but manual is one
    //     click away.

    @ViewBuilder
    private var emptyMeetingsState: some View {
        VStack(spacing: Sp.lg) {
            Image(systemName: "waveform.path")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.quaternary)
                // Slight opacity bump on top of .quaternary so the symbol
                // recedes further than the dictation-tab icon — it's bigger
                // here so it earns the extra restraint.
                .opacity(0.7)
                .padding(.bottom, Sp.xs)
            Text("No meetings yet")
                .font(.bodyMedium)
                .foregroundStyle(.primary)
            Text("Voice records meetings automatically when Zoom, Meet, Teams, or Discord is active. Or click Start Meeting Recording in the menu bar to record manually.")
                .font(.bodySmall)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Sp.xxl)
                .frame(maxWidth: 380)
            // Primary action — gives the empty state a way out without
            // making the user hunt for the menu bar.
            Button(action: {
                NotificationCenter.default.post(
                    name: .voiceStartMeetingManual,
                    object: nil
                )
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text("Start meeting manually")
                        .font(.bodySmall.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Sp.md)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .tint(Color.accentColor.opacity(0.16))
            .help("Start recording a meeting now — same as the menu bar item")
            .padding(.top, Sp.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Meetings loading state
    //
    // Shown only during the *first* DB read when no rows have landed yet.
    // Four skeleton rows with a slow shimmer — enough to communicate "we're
    // reading" without a hard spinner. After the first successful load,
    // reloads keep the existing list on screen rather than flash back to
    // this skeleton (see the .list branch in `body`).

    @ViewBuilder
    private var meetingsLoadingState: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Four rows so the loader has visual weight without dominating.
            // Stagger on row animation delays keeps the shimmer offsets
            // from looking too mechanical / pattern-y.
            MeetingSkeletonRow(animationDelay: 0.0)
            Divider().opacity(0.4)
            MeetingSkeletonRow(animationDelay: 0.15)
            Divider().opacity(0.4)
            MeetingSkeletonRow(animationDelay: 0.30)
            Divider().opacity(0.4)
            MeetingSkeletonRow(animationDelay: 0.45)
            Spacer(minLength: 0)
        }
        .padding(.top, Sp.sm)
    }

    // MARK: - Meetings error state
    //
    // Surfaces when the DB read throws — without this the storage failure
    // would render silently as "no meetings yet", which is misleading and
    // hides real DB problems. Carries the underlying message verbatim so
    // crash reports and debugging conversations have something to grep on.
    // The Retry button funnels through the same `fetchMeetingsIntoState()`
    // path as launch, so success will flip the load state back to .loaded
    // and this view will be replaced by either the list or the empty state.

    @ViewBuilder
    private func meetingsErrorState(reason: String) -> some View {
        VStack(spacing: Sp.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Sp.xxs)
            Text("Couldn't load meetings")
                .font(.bodyMedium)
                .foregroundStyle(.primary)
            Text(reason)
                .font(.bodySmall)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Sp.xxl)
                .frame(maxWidth: 420)
                .lineLimit(4)
            Button(action: {
                guard let app = NSApp.delegate as? AppDelegate else { return }
                app.reloadMeetingsFromDisk()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                    Text("Retry")
                        .font(.bodySmall.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Sp.md)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .tint(Color.accentColor.opacity(0.16))
            .help("Try reading meetings from disk again")
            .padding(.top, Sp.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Meeting skeleton row
//
// Single placeholder row used by the meetings loading state. Mimics the
// vertical rhythm of a real MeetingRow (title bar at the top, two short
// metadata lines) so when real rows land, layout doesn't jump. Shimmer is
// a subtle moving highlight across each bar — runs slow (1.4s) at low
// contrast so the loader reads as calm, not anxious.

private struct MeetingSkeletonRow: View {
    let animationDelay: Double

    @Environment(\.colorScheme) private var scheme
    @State private var shimmerPhase: CGFloat = -1.0

    private var baseColor: Color {
        scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
    }

    private var shimmerColor: Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            // Title placeholder — wider, taller.
            skeletonBar(width: 220, height: 12)
            // Metadata placeholders — staggered widths so they don't look
            // like a tiled pattern.
            HStack(spacing: Sp.sm) {
                skeletonBar(width: 90, height: 9)
                skeletonBar(width: 60, height: 9)
                skeletonBar(width: 110, height: 9)
            }
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Start the loop after the requested delay, then run forever.
            // Using DispatchQueue.asyncAfter instead of a delay-on-animation
            // so each row's phase stays independent and shimmer offsets
            // remain staggered across rows.
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDelay) {
                withAnimation(
                    .linear(duration: 1.4)
                    .repeatForever(autoreverses: false)
                ) {
                    shimmerPhase = 2.0
                }
            }
        }
    }

    @ViewBuilder
    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(baseColor)
            .frame(width: width, height: height)
            .overlay(
                // Moving highlight clipped to the bar's rounded rect. The
                // gradient is mostly transparent — only the middle band of
                // the linear gradient brushes across the bar, giving a soft
                // sweep rather than a hard line.
                GeometryReader { geo in
                    let bandWidth = geo.size.width * 0.6
                    LinearGradient(
                        stops: [
                            .init(color: shimmerColor.opacity(0.0), location: 0.0),
                            .init(color: shimmerColor, location: 0.5),
                            .init(color: shimmerColor.opacity(0.0), location: 1.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: shimmerPhase * (geo.size.width + bandWidth) - bandWidth)
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            )
            .allowsHitTesting(false)
    }
}

// MARK: - BigMenuTab

/// The two top-level tabs in BigMenuWindow.
enum BigMenuTab: String, CaseIterable, Identifiable {
    case dictations
    case meetings
    case video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dictations: return "Dictations"
        case .meetings:   return "Meetings"
        case .video:      return "Videos"
        }
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
        }
        // Native Liquid Glass, tinted orange. `.interactive()` makes the
        // surface deform under cursor + gives the press squish for free.
        .buttonStyle(.plain)
        // Tint dropped from 0.16/0.22 → 0.10/0.16 so the banner reads as a
        // subtle warning rather than competing with the shield + text +
        // chevron, all of which are already orange.
        .glassEffect(
            .regular.tint(.orange.opacity(isHovering ? 0.16 : 0.10)).interactive(),
            in: RoundedRectangle(cornerRadius: CardShape.corner)
        )
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
    @State private var displayValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            // Icon: stepped back to .tertiary 12pt so the serifValue number
            // is the single focal point on the card. Previously the 13pt
            // medium .secondary icon was competing with the label.
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(displayValue.isEmpty ? value : displayValue)
                .font(.serifValue)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.4), value: displayValue)
            // Label dropped to .bodySmall to match the icon's reduced weight
            // and recede behind the serif number.
            Text(label)
                .font(.bodySmall)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Sp.lg)
        .onAppear { displayValue = value }
        .onChange(of: value) { _, newVal in
            withAnimation(.spring(duration: 0.4)) { displayValue = newVal }
        }
        // FIXED height — was minHeight which let cards reflow when text wrapped.
        // 124pt locks the stat row into a consistent strip regardless of
        // label length or current values.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 124)
        // Reverted from .glassEffect to the older layered look — user said
        // the glass cards "look weird layering-wise" against the rest of
        // the menu. Solid tinted fill + hairline border reads as a calm
        // panel, not a floating glass tile.
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

// MARK: - Learned words card
//
// Wispr-style learn-from-correction words live in ProperNounVocabulary. This
// card surfaces them in the main Dictations tab (moved out of Settings) as a
// collapsible disclosure: count + scrollable word list with per-row remove,
// plus an add field. Self-contained — owns its own mirror of the store and
// re-reads customTerms() after every add/remove so the list stays in sync.
private struct LearnedWordsCard: View {
    @Environment(\.colorScheme) private var scheme

    @State private var terms: [String] = []
    @State private var draft: String = ""
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            // Header — tap anywhere to expand/collapse.
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: Sp.sm) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: Sp.xxs) {
                        Text("Learned words")
                            .font(.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Words VOICE learned from your corrections. Add your own names and jargon here.")
                            .font(.bodySmall)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: Sp.sm)
                    Text("\(terms.count)")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if expanded {
                if terms.isEmpty {
                    Text("No learned words yet. Correct a misheard word in any app and it'll show up here.")
                        .font(.bodyBase)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: Sp.xxs) {
                            ForEach(terms, id: \.self) { term in
                                HStack(spacing: Sp.xs) {
                                    Text(term)
                                        .font(.bodyBase)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        removeTerm(term)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.bodySmall)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Remove \(term)")
                                }
                                .padding(.vertical, Sp.xxs)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Cap the visible height so a very long list scrolls
                    // instead of growing the card indefinitely.
                    .frame(maxHeight: 220)
                }

                HStack(spacing: Sp.xs) {
                    TextField("Add a name or word", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { addTerm() }
                    Button("Add") { addTerm() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Matches the StatCard surface — solid tinted fill + hairline border —
        // so it reads as part of the same card family as the rest of the menu.
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
        .onAppear { reload() }
    }

    private func reload() {
        terms = ProperNounVocabulary.customTerms()
    }

    private func addTerm() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Ignore dupes (case-insensitive) so we don't add a word already learned.
        if terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            draft = ""
            return
        }
        ProperNounVocabulary.add(trimmed)
        draft = ""
        reload()
    }

    private func removeTerm(_ term: String) {
        ProperNounVocabulary.remove(term)
        reload()
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

    /// Convert "cloud:gpt-oss-120b" / "cloud:groq-llama3.1-8b" / "local:qwen3-1.7b" /
    /// "rules-only" into a human label for the metadata badge.
    static func engineDisplayLabel(_ raw: String) -> String {
        switch raw {
        case "cloud:gpt-oss-120b":              return "Cloud · GPT-OSS 120B"
        case "cloud:qwen-3-235b":               return "Cloud · Qwen 235B"  // legacy, may appear in older records
        case "cloud:nvidia-gpt-oss-120b":       return "Cloud · NVIDIA GPT-OSS 120B"
        case "cloud:hyperbolic-gpt-oss-120b":   return "Cloud · Hyperbolic GPT-OSS 120B"
        case "cloud:groq-llama3.1-8b":          return "Cloud · Groq Llama 3.1 8B"
        case "local:qwen3-4b":                  return "Local · Qwen3 4B"
        case "local:qwen3-1.7b":                return "Local · Qwen3 1.7B"
        case "rules-only":         return "Rules only"
        default:
            // Fallback: just strip the colon, show as is.
            return raw.replacingOccurrences(of: ":", with: " · ")
        }
    }

    /// Leading colored stripe — gray normally, accent while the copy
    /// confirmation is showing. Same at-a-glance state cue MeetingRow uses.
    private var stripeColor: Color {
        if showCopied { return .accentColor }
        return .secondary.opacity(0.30)
    }

    private var stateStripe: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(stripeColor)
            .frame(width: 3)
            .frame(maxHeight: .infinity)
    }

    /// One-line meta parts — engine · cleanup · personality · polish ms.
    /// Empty for legacy entries with none of these set, so the meta row
    /// collapses instead of rendering a stray separator.
    private var metaParts: [String] {
        var parts: [String] = []
        if let engine = optString("polishEngine") {
            parts.append(Self.engineDisplayLabel(engine))
        }
        if let level = optString("cleanupLevelUsed") {
            parts.append(level.capitalized)
        }
        if let style = optString("personalityStyleUsed") {
            parts.append(style.capitalized)
        }
        if let ms = item.polishMs {
            parts.append("\(ms)ms")
        }
        return parts
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Sp.md) {
                // Leading colored stripe — same at-a-glance cue MeetingRow uses.
                stateStripe

                VStack(alignment: .leading, spacing: Sp.xxs) {
                    // Title + relative time on a single line. Dictations have
                    // no name field, so we use a fixed "Dictation" label and
                    // let the preview line below carry the body text.
                    HStack(alignment: .firstTextBaseline, spacing: Sp.sm) {
                        Text("Dictation")
                            .font(.bodyMedium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: Sp.sm)
                        Text(timeString)
                            .font(.bodySmall)
                            .foregroundStyle(.tertiary)
                    }

                    // Meta line: engine · level · style · ms — same
                    // .bodySmall .secondary single-line treatment as
                    // MeetingRow's "source app · duration" row.
                    if !metaParts.isEmpty {
                        HStack(spacing: Sp.xs) {
                            ForEach(Array(metaParts.enumerated()), id: \.offset) { idx, part in
                                if idx > 0 {
                                    Text("·").foregroundStyle(.quaternary)
                                }
                                Text(part)
                            }
                        }
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    // State caption — accent-tinted "Copied" line. Plays the
                    // same role as MeetingRow's transient stateCaption.
                    if showCopied {
                        Text("Copied")
                            .font(.bodySmall)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .transition(.opacity)
                    }

                    // Transcript preview — italic, tertiary, 1-line collapsed.
                    Text(item.text)
                        .font(.bodySmall.italic())
                        .foregroundStyle(.tertiary)
                        .lineLimit(isExpanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(.top, Sp.xxs)
                        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: showCopied)

                    if isExpanded {
                        // Action row — explicit Copy affordance. Copying is
                        // no longer a side effect of tapping the row.
                        HStack(spacing: Sp.xs) {
                            Spacer()
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
                        .padding(.top, Sp.sm)

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
            }
            .padding(.horizontal, Sp.xl)
            .padding(.vertical, Sp.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isExpanded
                    ? Color.primary.opacity(0.05)
                    : (isHovering ? Color.primary.opacity(0.03) : Color.clear)
            )
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
                // Hairline divider — same style as MeetingRow (Sp.xl leading
                // inset so the line clears the stripe + content gutter).
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                    .padding(.leading, Sp.xl)
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: isExpanded)
    }
}


// MARK: - Meeting row (collapsed + expanded)

private struct MeetingRow: View {
    let meeting: Meeting
    @Binding var expandedID: UUID?
    @State private var copiedMarkdown: Bool = false
    @State private var copiedTranscript: Bool = false
    @State private var isTranscribing: Bool = false
    @State private var transcribeError: String? = nil
    /// Lazy audio player — only created when the row expands.
    @State private var audioPlayer = MeetingAudioPlayer()
    /// Hover state — drives the subtle background tint and the inline
    /// "•••" action affordance that's hidden by default to keep long lists calm.
    @State private var isHovering: Bool = false
    /// Toggled by the state stripe to drive the pulse animation. Lives on
    /// the parent view (not the stripe's closure) so the animation transform
    /// is owned by the same view that's animating.
    @State private var stripePulsed: Bool = false

    var isExpanded: Bool { expandedID == meeting.id }

    /// True when audio is on disk but no transcript has landed yet.
    /// We treat duration ≥ 5s as "real" to avoid badging 1-second test rows.
    private var isUntranscribed: Bool {
        guard meeting.segments.isEmpty, meeting.duration >= 5 else { return false }
        guard let path = meeting.audioFilePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private var audioMissing: Bool {
        guard let path = meeting.audioFilePath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    private func triggerTranscribe() {
        guard !isTranscribing else { return }
        isTranscribing = true
        transcribeError = nil
        // Post a notification; AppDelegate listens, runs retranscribe on its
        // own services (no fragile NSApp.delegate cast), and posts a
        // .voiceTranscribeMeetingFinished back which we observe to clear state.
        NotificationCenter.default.post(
            name: .voiceTranscribeMeetingRequested,
            object: nil,
            userInfo: ["meetingId": meeting.id.uuidString]
        )
    }

    /// Delete this meeting: removes the DB row AND the underlying audio file.
    /// Same notification-driven pattern as transcribe — AppDelegate owns the
    /// storage service so we post a request and let it handle teardown.
    private func deleteMeeting() {
        NotificationCenter.default.post(
            name: Notification.Name("voice.deleteMeetingRequested"),
            object: nil,
            userInfo: ["meetingId": meeting.id.uuidString]
        )
    }

    private var timeString: String {
        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()
        if cal.isDateInToday(meeting.date) {
            fmt.dateFormat = "h:mm a"
            return fmt.string(from: meeting.date)
        }
        if cal.isDateInYesterday(meeting.date) {
            fmt.dateFormat = "h:mm a"
            return "Yesterday, \(fmt.string(from: meeting.date))"
        }
        // "This week" — within the last 7 days and not today/yesterday.
        // Show the weekday name so a meeting on Monday reads "Monday, 2:34 PM"
        // instead of the more anonymous "Mar 24, 2:34 PM".
        if let days = cal.dateComponents([.day], from: meeting.date, to: now).day,
           days < 7, days >= 0 {
            fmt.dateFormat = "EEEE, h:mm a"
            return fmt.string(from: meeting.date)
        }
        fmt.dateFormat = "MMM d, h:mm a"
        return fmt.string(from: meeting.date)
    }

    private func formatMeetingDuration(_ t: TimeInterval) -> String {
        // Colon-formatted timecode — reads as a duration ("1:23") not a
        // verbose phrase ("1m 23s"). Falls into h:mm:ss for ≥1h sessions.
        let total = max(0, Int(t))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func sourceAppLabel(_ bundleID: String?) -> String {
        guard let id = bundleID else { return "Meeting" }
        let names: [String: String] = [
            "com.google.meet": "Google Meet",  "us.zoom.xos": "Zoom",
            "com.hnc.Discord": "Discord",       "ru.keepcoder.Telegram": "Telegram",
            "com.tinyspeck.slackmacgap": "Slack", "com.apple.FaceTime": "FaceTime",
            "com.cisco.webex.meetings": "Webex",  "net.whatsapp.WhatsApp": "WhatsApp",
            "com.microsoft.teams2": "Teams",   "com.skype.skype": "Skype",
            "com.apple.iChat": "Messages",
        ]
        return names[id] ?? "Meeting"
    }

    /// Short preview drawn from the first non-empty transcript segments.
    /// Replaces the old "Processing summary..." placeholder for meetings that
    /// were saved without AI summarization. Returns nil for empty transcripts.
    private func transcriptPreview(_ m: Meeting) -> String? {
        let joined = m.segments
            .lazy
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " ")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 240 { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: 240)
        return String(trimmed[..<cutoff]) + "…"
    }

    private func meetingMarkdown(_ m: Meeting) -> String {
        var out = "# \(m.title)\n\n"
        if let s = m.summary {
            out += "## Overview\n\(s.overview)\n\n"
            if !s.keyDecisions.isEmpty {
                out += "## Key Decisions\n" + s.keyDecisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
            if !s.actionItems.isEmpty {
                out += "## Action Items\n" + s.actionItems.map { item in
                    "- [ ] \(item.text)" + (item.assignee.map { " (@\($0))" } ?? "")
                }.joined(separator: "\n") + "\n\n"
            }
            if !s.openQuestions.isEmpty {
                out += "## Open Questions\n" + s.openQuestions.map { "- \($0)" }.joined(separator: "\n")
            }
        } else {
            out += "## Transcript\n" + m.segments.map { "[\($0.formattedTimestamp)] \($0.text)" }.joined(separator: "\n")
        }
        return out
    }

    // MARK: State machine
    //
    // Each row encodes its current life-cycle as one of these states. We
    // compute it once and use it to drive: the leading colored stripe, the
    // caption line under the title, the hero action button, and what
    // utility actions appear in the expanded toolbar. Single source of truth
    // — keeps the view body declarative and trivial to read.
    private enum RowState {
        case transcribed       // segments populated — normal happy state
        case transcribing      // user kicked off a manual re-run; waiting on it
        case untranscribed     // audio on disk, no segments yet
        case audioMissing      // segments empty AND audio file missing
        case failed            // last transcribe attempt failed
        case inProgress        // meeting is still being recorded right now
    }

    private var rowState: RowState {
        if isTranscribing { return .transcribing }
        if transcribeError != nil { return .failed }
        if meeting.title.hasPrefix("Recording ") && meeting.segments.isEmpty { return .inProgress }
        if let p = meeting.audioFilePath,
           !FileManager.default.fileExists(atPath: p),
           meeting.segments.isEmpty {
            return .audioMissing
        }
        if isUntranscribed { return .untranscribed }
        return .transcribed
    }

    private var stateColor: Color {
        switch rowState {
        // Completed rows render no stripe — keeps a long list calm. The
        // stripe view returns `.clear` for this state.
        case .transcribed:                      return .clear
        // Live recording: red, with the stripe view applying a smooth pulse.
        case .inProgress:                       return .red
        // Transcribing: solid amber so it visibly differs from "live red".
        case .transcribing:                     return .orange
        case .untranscribed:                    return .orange
        case .audioMissing, .failed:            return .red
        }
    }

    private var stateCaption: String? {
        switch rowState {
        case .transcribed:    return nil
        case .transcribing:   return "Transcribing…"
        case .untranscribed:  return "Audio only — tap to transcribe"
        case .audioMissing:   return "Audio file missing"
        case .failed:         return transcribeError ?? "Couldn't transcribe — tap to retry"
        case .inProgress:     return "Recording…"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Sp.md) {
                // Leading colored stripe — the at-a-glance state indicator.
                // Pulses while transcribing so the user sees something is
                // happening even if they're not expanded.
                stateStripe

                VStack(alignment: .leading, spacing: Sp.xxs) {
                    // Title + relative time + chevron + overflow menu on a
                    // single line. Title is the dominant element; time is
                    // muted tertiary so the eye lands on the title first.
                    // The chevron and "•••" menu fade in only on hover or
                    // when expanded, keeping a long list calm by default.
                    HStack(alignment: .firstTextBaseline, spacing: Sp.sm) {
                        Text(meeting.title)
                            .font(.bodyMedium.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: Sp.sm)
                        Text(timeString)
                            .font(.bodySmall)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        // Disclosure chevron — rotates 90° when expanded.
                        // Visible only on hover/expanded so collapsed rows
                        // stay quiet.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .opacity(isExpanded || isHovering ? 1 : 0)
                            .animation(.easeOut(duration: 0.18), value: isExpanded)
                            .animation(.easeOut(duration: 0.12), value: isHovering)
                        // Inline "•••" overflow menu — mirrors the right-click
                        // menu so non-power-users discover it. Same hover gate
                        // as the chevron.
                        rowOverflowMenu
                            .opacity(isHovering || isExpanded ? 1 : 0)
                            .animation(.easeOut(duration: 0.12), value: isHovering)
                    }

                    // Meta line: source app · duration. Muted secondary text,
                    // smaller weight than the title so the hierarchy reads
                    // title → meta → caption.
                    HStack(spacing: Sp.xs) {
                        Text(sourceAppLabel(meeting.sourceApp))
                        Text("·").foregroundStyle(.quaternary)
                        Text(formatMeetingDuration(meeting.duration))
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                    // State caption — small one-line summary of what's going on
                    // ("Transcribing…", "Audio only — tap to transcribe", etc).
                    // Quietly tinted to match the stripe.
                    if let caption = stateCaption {
                        Text(caption)
                            .font(.bodySmall)
                            .foregroundStyle(captionColor)
                            .lineLimit(1)
                    }

                    // Transcript preview — only shown when we actually have one.
                    // Collapsed = 1 line so the row reads as a label, not a paragraph.
                    if rowState == .transcribed {
                        if let overview = meeting.summary?.overview {
                            Text(overview)
                                .font(.bodySmall.italic())
                                .foregroundStyle(.tertiary)
                                .lineLimit(isExpanded ? nil : 1)
                                .multilineTextAlignment(.leading)
                                .padding(.top, Sp.xxs)
                        } else if let preview = transcriptPreview(meeting) {
                            Text(preview)
                                .font(.bodySmall.italic())
                                .foregroundStyle(.tertiary)
                                .lineLimit(isExpanded ? nil : 1)
                                .multilineTextAlignment(.leading)
                                .padding(.top, Sp.xxs)
                        }
                    }

                    if isExpanded {
                        // Subtle internal divider between header and expanded
                        // content so the body reads as belonging to this row.
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 1)
                            .padding(.top, Sp.sm)
                            .transition(.opacity)

                        expandedBody
                            .padding(.top, Sp.sm)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, Sp.xl)
            .padding(.vertical, Sp.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackgroundColor)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                // Pointing-hand cursor over the title area — same affordance
                // pattern as the pill / skin selector elsewhere in the app.
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    expandedID = isExpanded ? nil : meeting.id
                }
            }
            .contextMenu {
                if rowState == .untranscribed || rowState == .failed {
                    Button("Transcribe now") { triggerTranscribe() }
                }
                if !meeting.segments.isEmpty {
                    Button("Copy transcript") { copyTranscriptToClipboard() }
                    Button("Copy Markdown") { MeetingExporter().copyToClipboard(meeting) }
                }
                Button("Export Markdown…") {
                    Task {
                        guard let storage = (NSApp.delegate as? AppDelegate)?.coordinator.storage else { return }
                        _ = await MeetingExporter().exportToFile(meeting, storage: storage)
                    }
                }
                Divider()
                Button("Delete meeting", role: .destructive) {
                    deleteMeeting()
                }
            }

            // Hairline divider — same style as DictationRow
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
                .padding(.leading, Sp.xl)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: isExpanded)
        // Auto-pause when this row collapses. Without this, the user can
        // start playback, collapse the row, and audio keeps going from a
        // surface they can no longer see or scrub. Belt-and-braces with the
        // shared coordinator: even if no other row takes over, we stop.
        .onChange(of: isExpanded) { _, nowExpanded in
            if !nowExpanded { audioPlayer.pauseIfPlaying() }
        }
        // Listen for transcribe-finished events from VoiceApp. Match by ID
        // so a sibling row's completion doesn't clear our state.
        .onReceive(NotificationCenter.default.publisher(for: .voiceTranscribeMeetingFinished)) { note in
            guard let idStr = note.userInfo?["meetingId"] as? String,
                  idStr == meeting.id.uuidString else { return }
            let success = note.userInfo?["success"] as? Bool ?? false
            let err = note.userInfo?["error"] as? String
            isTranscribing = false
            transcribeError = success ? nil : (err ?? "Transcription failed.")
        }
    }

    // MARK: View pieces

    /// Foreground tint for the caption text. The stripe is now `.clear` for
    /// transcribed rows, so we can't reuse `stateColor` here without making
    /// "Transcribing…" / "Audio only…" captions disappear when the stripe is
    /// clear. Fall back to `.secondary` whenever the stripe wouldn't tint.
    private var captionColor: Color {
        switch rowState {
        case .transcribed:                  return .secondary
        case .inProgress:                   return .red
        case .transcribing:                 return .orange
        case .untranscribed:                return .orange
        case .audioMissing, .failed:        return .red
        }
    }

    /// Subtle background for the row. Solid tint when expanded, hover tint
    /// when hovered, transparent otherwise. Keeps a long list calm and gives
    /// a clear "this row is interactive" affordance.
    private var rowBackgroundColor: Color {
        if isExpanded { return Color.primary.opacity(0.05) }
        if isHovering { return Color.primary.opacity(0.03) }
        return .clear
    }

    /// "•••" menu that mirrors the right-click context menu. Sits flush
    /// against the trailing edge of the row and only renders on hover or
    /// when the row is expanded.
    private var rowOverflowMenu: some View {
        Menu {
            if rowState == .untranscribed || rowState == .failed {
                Button("Transcribe now") { triggerTranscribe() }
            }
            if !meeting.segments.isEmpty {
                Button("Copy transcript") { copyTranscriptToClipboard() }
                Button("Copy Markdown") { MeetingExporter().copyToClipboard(meeting) }
            }
            Button("Export Markdown…") {
                Task {
                    guard let storage = (NSApp.delegate as? AppDelegate)?.coordinator.storage else { return }
                    _ = await MeetingExporter().exportToFile(meeting, storage: storage)
                }
            }
            Divider()
            Button("Delete meeting", role: .destructive) { deleteMeeting() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var stateStripe: some View {
        // 3pt-wide colored bar pinned to the left edge. Live recording pulses
        // (red, breathing) and active transcription pulses (amber, slower);
        // completed rows render no stripe at all so the list reads cleaner.
        // Width is constant across states so the title column never shifts.
        RoundedRectangle(cornerRadius: 1.5)
            .fill(stateColor)
            .frame(width: 3)
            .frame(maxHeight: .infinity)
            // When pulsing, opacity oscillates because `stripePulsed` flips
            // to true on appear and the animation modifier autoreverses the
            // transition forever. When NOT pulsing, the stripe is solid.
            .opacity(stripePulses && stripePulsed ? 0.45 : 1.0)
            .animation(
                stripePulses
                    ? .easeInOut(duration: rowState == .inProgress ? 0.8 : 1.1)
                        .repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: stripePulsed
            )
            .onAppear { stripePulsed = true }
    }

    /// Which states get an animated "breathing" stripe.
    private var stripePulses: Bool {
        rowState == .inProgress || rowState == .transcribing
    }

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            // Hero action when there's a primary thing to do.
            if let hero = heroAction {
                heroButton(hero)
            }

            // Inline audio player. Only shown when the audio file is on disk.
            // Tapping a transcript segment below seeks into this player.
            if let path = meeting.audioFilePath,
               FileManager.default.fileExists(atPath: path) {
                MeetingAudioPlayerBar(player: audioPlayer)
                    .onAppear {
                        audioPlayer.load(URL(fileURLWithPath: path))
                    }
            }

            // LLM-generated summary — overview + key decisions + action items.
            // Shown above the transcript so the eye lands on the synthesis
            // first; transcript is for diving in. We surface the empty-summary
            // fallback when ALL four summary fields are blank, with a
            // Re-transcribe shortcut wired into the same flow the hero action
            // uses (NotificationCenter → AppDelegate → MeetingRecoveryService).
            if let summary = meeting.summary {
                MeetingSummaryBlock(
                    summary: summary,
                    onActionItemToggled: { itemId, completed in
                        toggleActionItem(itemId: itemId, completed: completed)
                    },
                    onRetranscribe: meeting.audioFilePath.flatMap { path in
                        FileManager.default.fileExists(atPath: path)
                            ? { triggerTranscribe() }
                            : nil
                    }
                )
            }

            // Full transcript with speaker color coding. Hidden behind a
            // disclosure so it doesn't push the action buttons way down for
            // 50-minute meetings. Defaults to closed; user clicks to read.
            if !meeting.segments.isEmpty {
                DisclosureGroup {
                    MeetingTranscriptView(
                        segments: meeting.segments,
                        onSeekRequested: { time in
                            audioPlayer.seek(to: time)
                            if !audioPlayer.isPlaying { audioPlayer.togglePlay() }
                        }
                    )
                        .padding(.top, Sp.xs)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 11, weight: .medium))
                        Text("Transcript · \(meeting.segments.count) segment\(meeting.segments.count == 1 ? "" : "s")")
                            .font(.bodySmall.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .onTapGesture { /* allow disclosure default */ }
            }

            // Utility row: icon-only secondary actions. Show only what's
            // applicable for the current state so the row never reads as
            // a crowded toolbar.
            HStack(spacing: Sp.lg) {
                if !meeting.segments.isEmpty {
                    iconAction(
                        copiedTranscript ? "checkmark" : "doc.on.doc",
                        copiedTranscript ? "Copied" : "Copy transcript",
                        action: copyTranscriptToClipboard
                    )
                    iconAction(
                        copiedMarkdown ? "checkmark" : "text.quote",
                        copiedMarkdown ? "Copied" : "Copy Markdown",
                        action: {
                            MeetingExporter().copyToClipboard(meeting)
                            copiedMarkdown = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedMarkdown = false
                            }
                        }
                    )
                    iconAction("square.and.arrow.up", "Export") {
                        Task {
                            guard let storage = (NSApp.delegate as? AppDelegate)?.coordinator.storage else { return }
                            _ = await MeetingExporter().exportToFile(meeting, storage: storage)
                        }
                    }
                }
                Spacer()
            }
        }
    }

    // Hero action descriptor — the single biggest thing to do on the row.
    private struct HeroAction {
        let label: String
        let icon: String
        let tint: Color
        let action: () -> Void
        let disabled: Bool
    }

    private var heroAction: HeroAction? {
        switch rowState {
        case .untranscribed:
            return HeroAction(
                label: "Transcribe now",
                icon: "waveform.circle.fill",
                tint: .accentColor,
                action: triggerTranscribe,
                disabled: false
            )
        case .failed:
            return HeroAction(
                label: "Retry transcription",
                icon: "arrow.clockwise.circle.fill",
                tint: .red,
                action: triggerTranscribe,
                disabled: false
            )
        case .transcribing:
            return HeroAction(
                label: "Transcribing…",
                icon: "ellipsis.circle.fill",
                tint: .accentColor,
                action: {},
                disabled: true
            )
        case .audioMissing:
            return HeroAction(
                label: "Audio file missing",
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                action: {},
                disabled: true
            )
        case .transcribed, .inProgress:
            return nil
        }
    }

    private func heroButton(_ h: HeroAction) -> some View {
        // Compact pill button — fits naturally inline with the row content
        // instead of slabbing across the whole expanded view. The full-width
        // tinted slab was visually screaming and made the row feel like an
        // alert dialog, not a list entry.
        //
        // BUGFIX (rounding/clipping): previously used `.buttonStyle(.glass)`
        // PLUS custom inner padding PLUS `.fixedSize()`. The `.glass` style
        // provides its OWN background pill sized to system metrics; layering
        // our own padding on top inflated the content box past the glass
        // material, so the corners read as "off" and the inner content
        // clipped against the glass edge. Fix: use the same explicit pattern
        // as PermissionsBanner — `.buttonStyle(.plain)` + a `.glassEffect`
        // in an explicit `Capsule()` that matches the `.contentShape`. Shape
        // is identical for hit-test, material, and clip — no mismatch, and
        // the corner radius tracks the actual content height automatically.
        Button(action: h.action) {
            HStack(spacing: 6) {
                Image(systemName: h.icon)
                    .font(.bodySmall.weight(.medium))
                Text(h.label)
                    .font(.bodySmall.weight(.medium))
            }
            .padding(.horizontal, Sp.md)
            .padding(.vertical, 6)
            .foregroundStyle(h.tint)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(h.tint.opacity(0.18)).interactive(),
            in: Capsule(style: .continuous)
        )
        .fixedSize()
        .disabled(h.disabled)
    }

    private func iconAction(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Sp.xs) {
                Image(systemName: icon).font(.bodySmall)
                Text(label).font(.bodySmall)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    /// Toggle an action item's `isCompleted` flag and persist. We re-fetch
    /// the meeting from the DB (this row's `meeting` is a snapshot from the
    /// parent list and is immutable for SwiftUI), mutate the summary, save
    /// it back, and ask the AppDelegate to reload meetings so the view
    /// rerenders with the new state.
    private func toggleActionItem(itemId: UUID, completed: Bool) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        Task { @MainActor in
            let all = app.coordinator.fetchAllMeetings()
            guard var m = all.first(where: { $0.id == meeting.id }),
                  var summary = m.summary else { return }
            guard let idx = summary.actionItems.firstIndex(where: { $0.id == itemId }) else { return }
            summary.actionItems[idx].isCompleted = completed
            m.summary = summary
            do {
                try app.coordinator.saveMeeting(m)
                app.reloadMeetingsFromDisk()
            } catch {
                print("[VOICE-ACTION] save failed: \(error)")
            }
        }
    }

    private func copyTranscriptToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meetingMarkdown(meeting), forType: .string)
        copiedTranscript = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedTranscript = false
        }
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
    @Environment(\.colorScheme) private var scheme

    @AppStorage("autoPaste")        private var autoPaste: Bool = true
    @AppStorage("autoCopy")         private var autoCopy: Bool = true
    @AppStorage("soundEffectsEnabled") private var soundEffects: Bool = true
    @AppStorage("llmPolishEnabled") private var llmPolishEnabled: Bool = LLMPolisher.isAvailable
    // Engine choice: cloud is default for better quality + faster latency
    // on long inputs. User can switch to local for privacy or offline use.
    @AppStorage("cerebrasEnabled")  private var cerebrasEnabled: Bool = true
    @AppStorage("cerebrasAPIKey")   private var cerebrasAPIKey: String = ""
    /// NVIDIA NIM is the PRIMARY cloud provider — tried before Cerebras. Free
    /// 40 RPM account-level at build.nvidia.com, no credit card. When NVIDIA
    /// is rate-limited or credits-exhausted, polish falls through to Cerebras.
    @AppStorage("voice.nvidiaAPIKey") private var nvidiaAPIKey: String = ""
    /// Hyperbolic is an optional second cloud fallback. Sits between Cerebras
    /// and Groq in the chain: when Cerebras is rate-limited we try Hyperbolic
    /// (same gpt-oss-120b model) before demoting to Groq's smaller 8B.
    @AppStorage("voice.hyperbolicAPIKey") private var hyperbolicAPIKey: String = ""
    /// Collapses the secondary (Cerebras / Hyperbolic) cloud-key fields behind
    /// a disclosure so Settings leads with just the NVIDIA primary key.
    @State private var showFallbackProviders = false
    /// Collapses all power-user / debug / rarely-touched controls behind a
    /// single disclosure at the bottom so the main settings list stays short.
    @State private var showAdvanced = false
    /// When a key is already set we render it LOCKED (read-only, masked) so a
    /// stray click can't corrupt it — the user must explicitly tap "Change"
    /// to edit. These flags track which key field is currently unlocked.
    @State private var editingCerebrasKey = false
    @State private var editingNvidiaKey = false
    @State private var editingHyperbolicKey = false

    /// Masks a stored API key for the locked display: prefix + dots.
    private static func maskKey(_ k: String) -> String {
        guard k.count > 10 else { return String(repeating: "•", count: max(4, k.count)) }
        return String(k.prefix(8)) + "…" + String(repeating: "•", count: 4)
    }

    /// A cloud-key field that is LOCKED (masked, read-only) once a key is set,
    /// with a "Change" button to unlock editing — prevents accidental edits
    /// from a misclick. Shows the editable SecureField when empty or unlocked.
    @ViewBuilder
    private func lockableKeyRow(label: String, key: Binding<String>, editing: Binding<Bool>, getKeyURL: String) -> some View {
        if !key.wrappedValue.isEmpty && !editing.wrappedValue {
            HStack(spacing: Sp.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.bodySmall)
                    .foregroundStyle(.green)
                Text("\(label) set · \(Self.maskKey(key.wrappedValue))")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change") { editing.wrappedValue = true }
                    .buttonStyle(.plain)
                    .font(.bodySmall)
                    .foregroundStyle(.blue)
            }
        } else {
            HStack(spacing: Sp.xs) {
                Image(systemName: "key.fill")
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                SecureField("\(label) API key", text: key)
                    .textFieldStyle(.roundedBorder)
                    .font(.bodySmall)
                if !key.wrappedValue.isEmpty {
                    Button("Done") { editing.wrappedValue = false }
                        .buttonStyle(.plain)
                        .font(.bodySmall)
                        .foregroundStyle(.blue)
                } else {
                    Link("Get key", destination: URL(string: getKeyURL)!)
                        .font(.bodySmall)
                }
            }
        }
    }
    /// Hands-free wake phrase ("Hey Voice"). Off by default — costs battery.
    @AppStorage("voice.wakeWordEnabled") private var wakeWordEnabled: Bool = false
    /// Editable wake phrase. Default "hey voice". Lowercased on use.
    @AppStorage("voice.wakeWord") private var wakeWordPhrase: String = "hey voice"
    /// Wake word mode — "off" or "activatedWindow". The always-listening
    /// ("alwaysOn") mode was removed because the continuous mic recognizer
    /// caused spurious system triggers; a stored "alwaysOn" is migrated to
    /// "off" on appear. "activatedWindow" is a safe, time-boxed listen window.
    @AppStorage("voice.wakeWordMode") private var wakeWordMode: String = "off"
    /// Window duration in minutes for the "activatedWindow" wake mode.
    @AppStorage("voice.wakeWordWindowMinutes") private var wakeWordWindowMinutes: Int = 5
    /// Stop word — the hands-free counterpart to the wake word. Spoken at the
    /// end of a locked recording to commit it. On by default. Only active in
    /// hands-free (locked) mode; PTT stops on key release.
    @AppStorage("voice.stopWordEnabled") private var stopWordEnabled: Bool = true
    /// Editable stop phrase. Default "over and out" — a radio sign-off made of
    /// common words (ASR transcribes it reliably) that nobody naturally ends a
    /// dictation with, so false positives are near zero AND it's recognized
    /// dependably (unlike "finito", which ASR mangled).
    @AppStorage("voice.stopWord") private var stopWord: String = "halt"
    /// Master kill switch — disable the meeting auto-detection heuristic so
    /// VOICE never opens a recording on its own.
    @AppStorage("voice.disableMeetingDetection") private var disableMeetingDetection: Bool = false
    /// Privacy mode — disables every background AI behavior in one switch.
    @AppStorage("voice.privacyMode") private var privacyMode: Bool = false
    /// Horizontal anchor for the floating pill. Values: "bottomLeft" / "bottomCenter" / "bottomRight".
    @AppStorage("voice.pillPosition") private var pillPosition: String = "bottomCenter"
    /// Latency kill switch for the Qwen3 polish stage. Distinct key from
    /// `llmPolishEnabled` (which the polisher itself reads) — this is the
    /// UI-facing fast-paste toggle the latency agent reads in finishRecording.
    @AppStorage("polishEnabled")    private var polishEnabled: Bool = true
    @AppStorage("cleanupLevel")     private var cleanupLevel: String = "medium"
    @AppStorage("personalityStyle") private var personality: String = "neutral"
    /// When ON, VOICE auto-selects a writing personality based on the frontmost
    /// app (e.g. casual in iMessage, formal in Mail). Off by default — opt-in
    /// because some users want a single voice everywhere.
    @AppStorage("voice.autoPersonality") private var autoPersonality: Bool = false
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
    @State private var pttBindings:    [CapturedHotkey] = HotkeyRole.pushToTalk.loadBindings()
    @State private var lockBindings:   [CapturedHotkey] = HotkeyRole.handsFree.loadBindings()

    /// True when the stored UserDefaults key looks valid (csk- prefix,
    /// ≥20 chars). When false, CerebrasPolisher silently falls back to
    /// the bundled key (CerebrasKey.bundled) — so cloud still works.
    private var cerebrasKeyLooksValid: Bool {
        cerebrasAPIKey.hasPrefix("csk-") && cerebrasAPIKey.count >= 20
    }

    /// What CerebrasPolisher will actually use, after the bundled fallback.
    /// As long as either UserDefaults OR the bundled key is non-empty, cloud
    /// is reachable.
    private var effectiveCloudReady: Bool {
        if cerebrasKeyLooksValid { return true }
        return !CerebrasKey.bundled.isEmpty
    }

    private var polishStatusColor: Color {
        if cerebrasEnabled {
            return effectiveCloudReady ? .green : .red
        }
        switch Qwen3Polisher.availabilityStatus {
        case .available:             return .green
        case .downloading, .loading: return .orange
        case .notDownloaded:         return .yellow
        case .error:                 return .red
        }
    }

    private var polishStatusLabel: String {
        if cerebrasEnabled {
            if cerebrasKeyLooksValid {
                return "Cloud ready (Cerebras GPT-OSS 120B · your key)"
            }
            if !CerebrasKey.bundled.isEmpty {
                return "Cloud ready (Cerebras GPT-OSS 120B · bundled key)"
            }
            return "No cloud key configured — running on LOCAL"
        }
        return "Local: \(Qwen3Polisher.availabilityStatus.displayLabel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.serifTitle)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.serifSection)
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Sp.xl)
            .padding(.top, Sp.xl)
            .padding(.bottom, Sp.lg)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Sp.lg) {
                    // 1. ENGINE — local vs cloud. Top of settings so the user
                    // sees this first. The two EngineCards ARE the cards for
                    // this section, so we don't double-wrap; the section just
                    // gets a serif group header above the row.
                    cardRowSection("Engine", subtitle: "Where polishing runs.") {
                        VStack(alignment: .leading, spacing: Sp.md) {
                            HStack(spacing: Sp.md) {
                                EngineCard(
                                    icon: "cloud",
                                    title: "Cloud",
                                    tagline: "Fast, frontier quality.",
                                    example: "Cerebras gpt-oss-120b, ~0.3s. Long rants, lists, and structure handled cleanly. Falls back automatically if busy.",
                                    isSelected: cerebrasEnabled,
                                    onTap: { cerebrasEnabled = true }
                                )
                                EngineCard(
                                    icon: "laptopcomputer",
                                    title: "Local",
                                    tagline: "On-device, private, works offline.",
                                    example: "Qwen3 via MLX. Never leaves your Mac. Long input still routes to cloud when available.",
                                    isSelected: !cerebrasEnabled,
                                    onTap: { cerebrasEnabled = false }
                                )
                            }
                            if cerebrasEnabled {
                                // API key + cloud-tuning toggles get their own
                                // canonical card so they don't read as a bare
                                // strip below the engine cards.
                                canonicalCard(title: "Cloud API key", subtitle: "Works out of the box. Paste your own key for higher limits.") {
                                    VStack(alignment: .leading, spacing: Sp.sm) {
                                        // Cerebras — the primary. gpt-oss-120b at ~0.3s,
                                        // no clog. A working key ships bundled so cloud
                                        // works immediately; a pasted key raises limits.
                                        VStack(alignment: .leading, spacing: Sp.xxs) {
                                            lockableKeyRow(label: "Cerebras", key: $cerebrasAPIKey, editing: $editingCerebrasKey, getKeyURL: "https://cloud.cerebras.ai")
                                            Text("Primary cloud. Free at cloud.cerebras.ai — paste your own key for higher rate limits.")
                                                .font(.bodySmall)
                                                .foregroundStyle(.secondary)
                                        }

                                        // Secondary providers collapsed by default — they
                                        // only kick in if Cerebras is unavailable.
                                        DisclosureGroup(isExpanded: $showFallbackProviders) {
                                            VStack(alignment: .leading, spacing: Sp.sm) {
                                                lockableKeyRow(label: "NVIDIA", key: $nvidiaAPIKey, editing: $editingNvidiaKey, getKeyURL: "https://build.nvidia.com/openai/gpt-oss-120b")
                                                lockableKeyRow(label: "Hyperbolic", key: $hyperbolicAPIKey, editing: $editingHyperbolicKey, getKeyURL: "https://hyperbolic.xyz")
                                                Text("Optional fallbacks. Used only if Cerebras is unavailable.")
                                                    .font(.bodySmall)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.top, Sp.xs)
                                        } label: {
                                            Text("Advanced · fallback providers")
                                                .font(.bodySmall)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 2. Writing personality — protected card row.
                    cardRowSection("Writing personality", subtitle: "How VOICE finishes your sentences.") {
                        VStack(alignment: .leading, spacing: Sp.md) {
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
                    }

                    // 4. Rewrite intensity — protected card row.
                    cardRowSection("Rewrite intensity", subtitle: "How aggressively VOICE edits what you said.") {
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
                    }

                    // 5. Hotkeys — push-to-talk + hands-free bind here.
                    cardRowSection("Hotkeys", subtitle: "Bind one or more shortcuts per role.") {
                        VStack(alignment: .leading, spacing: Sp.md) {
                            HotkeyRoleCard(role: .pushToTalk, bindings: $pttBindings)
                                .frame(maxWidth: .infinity)
                            HotkeyRoleCard(role: .handsFree,  bindings: $lockBindings)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    // 6. Stop word — the spoken counterpart to lock-exit.
                    // Kept in the main list because hands-free lock mode is
                    // reachable via the hotkey triple-tap, not just wake word.
                    // (Wake word itself now lives under Advanced.)
                    canonicalCard(
                        title: "Stop word",
                        subtitle: "Say a word to end a hands-free recording. Push-to-talk stops when you release the key."
                    ) {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            toggle("End hands-free dictation when I say \"\(stopWord)\"", isOn: $stopWordEnabled)
                            if stopWordEnabled {
                                HStack(spacing: Sp.xs) {
                                    Text("Stop word")
                                        .font(.bodySmall)
                                        .foregroundStyle(.secondary)
                                    TextField("halt", text: $stopWord)
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.small)
                                        .frame(maxWidth: 200)
                                        .onChange(of: stopWord) { _, newValue in
                                            stopWord = newValue.lowercased()
                                        }
                                }
                            }
                        }
                    }

                    // 7. Output — paste, copy, sounds.
                    canonicalCard(
                        title: "Output",
                        subtitle: "What happens after VOICE finishes transcribing."
                    ) {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            toggle("Paste automatically", isOn: $autoPaste)
                            toggle("Copy to clipboard", isOn: $autoCopy)
                            toggle("Sound effects", isOn: $soundEffects)
                        }
                    }

                    // 8. Pill style — pill skin selector wrapped in canonical card.
                    canonicalCard(
                        title: "Pill style",
                        subtitle: "Choose how the recording pill looks on screen."
                    ) {
                        VStack(alignment: .leading, spacing: Sp.md) {
                            PillSkinSelector()

                            // Corner anchor — also draggable directly on the pill.
                            Picker("Position", selection: $pillPosition) {
                                Text("Bottom left").tag("bottomLeft")
                                Text("Bottom center").tag("bottomCenter")
                                Text("Bottom right").tag("bottomRight")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    // 8b. Privacy & Background — high-stakes kill switches.
                    // Rare but important; sits low, just above Advanced.
                    canonicalCard(
                        title: "Privacy & Background",
                        subtitle: "Master kill switches for background AI behavior. Active dictation hotkey is unaffected."
                    ) {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            toggle("Disable meeting auto-detection", isOn: $disableMeetingDetection)
                            toggle("Privacy mode (disable all background AI)", isOn: $privacyMode)
                        }
                    }

                    // 9. Advanced — everything power-user / rarely-touched
                    // collapsed behind one disclosure so the main list stays
                    // short: smart-correction status, per-app personality,
                    // My voice style match, permissions detail, debug tools.
                    canonicalCard(
                        title: "Advanced",
                        subtitle: "Power-user options. Most people never need these."
                    ) {
                        DisclosureGroup(isExpanded: $showAdvanced) {
                            VStack(alignment: .leading, spacing: Sp.lg) {
                                // Smart corrections + its live engine status.
                                VStack(alignment: .leading, spacing: Sp.xs) {
                                    toggle("Smart corrections", isOn: $llmPolishEnabled)
                                    HStack(spacing: Sp.xs) {
                                        Circle()
                                            .fill(polishStatusColor)
                                            .frame(width: 6, height: 6)
                                        Text(polishStatusLabel)
                                            .font(.bodySmall)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.leading, Sp.xl)
                                }

                                toggle("Auto-pick personality based on frontmost app", isOn: $autoPersonality)

                                // Wake word — power-user, off by default. Lives
                                // here so it isn't prominent; the dangerous
                                // always-listening mode has been removed entirely.
                                VStack(alignment: .leading, spacing: Sp.xs) {
                                    Text("Wake word")
                                        .font(.bodyMedium)
                                    Text("Say a phrase to start dictating, hands-free. On-device; uses ~3-5% CPU only while a window is active. Off by default.")
                                        .font(.bodySmall)
                                        .foregroundStyle(.secondary)
                                    wakeWordControls
                                }

                                // My voice — style match from samples.
                                VStack(alignment: .leading, spacing: Sp.xs) {
                                    Text("My voice")
                                        .font(.bodyMedium)
                                    Text("Match your own writing style. Extracted once from samples you provide.")
                                        .font(.bodySmall)
                                        .foregroundStyle(.secondary)
                                    MyStyleSection()
                                }

                                // Permissions — also mirrored in the top-of-window banner.
                                VStack(alignment: .leading, spacing: Sp.sm) {
                                    Text("Permissions")
                                        .font(.bodyMedium)
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

                                // Debug — polish replay harness.
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
                            .padding(.top, Sp.sm)
                        } label: {
                            Text("Show advanced options")
                                .font(.bodySmall)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, Sp.xl)
                .padding(.vertical, Sp.lg)
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
        .frame(minWidth: 820, idealWidth: 820, minHeight: 720, idealHeight: 720)
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
            // Migrate away from the removed always-listening wake mode. A stale
            // "alwaysOn" value would otherwise keep the continuous mic recognizer
            // alive (the auto-play-music bug). Treat it as "off".
            if wakeWordMode == "alwaysOn" {
                wakeWordMode = "off"
                wakeWordEnabled = false
            }
            Task { @MainActor in
                await Task.yield()
                permissions.refresh()
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                DispatchQueue.main.async {
                    permissions.refresh()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: pttBindings)    { _, new in HotkeyRole.pushToTalk.saveBindings(new) }
        .onChange(of: lockBindings)   { _, new in HotkeyRole.handsFree.saveBindings(new) }
    }

    /// Section for protected card rows (Engine, Personality, Cleanup, Polish,
    /// Hotkeys). The row of cards IS the card surface here, so we don't wrap
    /// it again — we just put a serif group header above it.
    @ViewBuilder
    private func cardRowSection<C: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.serifSection)
                if let subtitle {
                    Text(subtitle)
                        .font(.bodyBase)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Sp.xs)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Canonical glass card matching EngineCard / PersonalityCard / CleanupCard.
    /// Use for every non-card-row section so all of Settings reads as one
    /// rounded-rectangle family.
    @ViewBuilder
    private func canonicalCard<C: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.serifSection)
                if let subtitle {
                    Text(subtitle)
                        .font(.bodyBase)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Sp.xs)
                }
            }
            content()
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(.regularMaterial)
        )
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: CardShape.corner)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: CardShape.borderUnselected
                )
        )
    }

    /// Wake-word enable + mode + window + phrase. The always-listening mode was
    /// removed: only "Off" and the safe, time-boxed "Activate for window" remain.
    @ViewBuilder
    private var wakeWordControls: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            toggle("Enable \"\(wakeWordPhrase)\"", isOn: $wakeWordEnabled)
                .onChange(of: wakeWordEnabled) { _, isOn in
                    // Keep mode coherent with the master toggle. Enabling wake
                    // word selects the safe, time-boxed window mode.
                    if isOn {
                        if wakeWordMode != "activatedWindow" { wakeWordMode = "activatedWindow" }
                    } else {
                        wakeWordMode = "off"
                    }
                }

            if wakeWordEnabled {
                Picker("Wake Word Mode", selection: $wakeWordMode) {
                    Text("Off").tag("off")
                    Text("Activate for window").tag("activatedWindow")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()

                if wakeWordMode == "activatedWindow" {
                    Stepper(
                        "Window duration: \(wakeWordWindowMinutes) min",
                        value: $wakeWordWindowMinutes,
                        in: 1...30
                    )
                    .font(.bodySmall)
                    .controlSize(.small)
                }

                HStack(spacing: Sp.xs) {
                    Text("Phrase")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                    TextField("hey voice", text: $wakeWordPhrase)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 200)
                        .onChange(of: wakeWordPhrase) { _, newValue in
                            wakeWordPhrase = newValue.lowercased()
                        }
                }
            }
        }
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

    private func openPane(_ key: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Engine card
//
// Two-option selector card: Cloud (Cerebras) vs Local. Larger icon, title,
// and tagline. Tap selects. Matches the visual density of cleanup/personality
// cards so the Settings sheet feels cohesive.

private struct EngineCard: View {
    let icon: String
    let title: String
    let tagline: String
    let example: String
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            VStack(alignment: .leading, spacing: Sp.xs) {
                HStack(spacing: Sp.xs) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(title)
                        .font(.serifSection)
                }
                Text(tagline)
                    .font(.bodyBase)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            Text(example)
                .font(.sans(10, weight: .regular).italic())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Sp.sm)
                .padding(.vertical, Sp.xs)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                )
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, minHeight: 165, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(.regularMaterial)
        )
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: CardShape.corner)
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
                .font(.sans(10, weight: .regular).italic())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Sp.sm)
                .padding(.vertical, Sp.xs)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.08))
                )
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, minHeight: 165, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(.regularMaterial)
        )
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: CardShape.corner)
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
                .font(.sans(10, weight: .regular).italic())
                .padding(.horizontal, Sp.sm)
                .padding(.vertical, Sp.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
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
        .frame(maxWidth: .infinity, minHeight: 165, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(.regularMaterial)
        )
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: CardShape.corner)
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

// MARK: - My Style Section
//
// Full setup + spectrum flow for the Style Card feature. Self-contained —
// manages its own extract state machine so SettingsSheet stays simple.
//
// States:
//   off  → just the toggle header
//   on, no card  → textarea + word count + Extract button
//   on, extracting → spinner
//   on, card ready → status row + 4 spectrum level cards + Update button
//   error → error text inline with input

private struct MyStyleSection: View {
    @AppStorage("myStyleEnabled") private var isEnabled: Bool = false
    @AppStorage("myStyleLevel")   private var levelRaw: String = "polished"

    @State private var sampleText: String = ""
    @State private var isExtracting: Bool = false
    @State private var extractError: String? = nil
    @State private var hasCard: Bool = false
    @State private var cardWords: Int = 0
    @State private var showSampleInput: Bool = false

    private var wordCount: Int { sampleText.split { $0.isWhitespace }.count }
    private var canExtract: Bool { wordCount >= StyleCardService.minWords }

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            // Toggle header — always visible
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Match my writing style")
                        .font(.bodyBase)
                    Text("Extracted once from your own writing. Applied on top of your personality preset — sounds like you, not generic AI.")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if isEnabled {
                if hasCard && !showSampleInput && !isExtracting {
                    cardActiveView
                } else if isExtracting {
                    extractingView
                } else {
                    sampleInputView
                }
            }
        }
        .onAppear {
            hasCard    = StyleCardService.shared.hasCard
            cardWords  = StyleCardService.shared.cardWordCount
            showSampleInput = !StyleCardService.shared.hasCard
        }
    }

    // MARK: Card active state

    @ViewBuilder private var cardActiveView: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            // Status bar
            HStack(spacing: Sp.sm) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.18))
                        .frame(width: 20, height: 20)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                }
                Text("Your style is active")
                    .font(.bodyMedium)
                if cardWords > 0 {
                    Text("·  \(cardWords) words analyzed")
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update") { showSampleInput = true }
                    .buttonStyle(.borderless)
                    .font(.bodySmall)
                    .foregroundStyle(Color.accentColor)
                    .controlSize(.small)
            }

            // Spectrum cards
            HStack(alignment: .top, spacing: Sp.md) {
                ForEach(MyStyleLevel.allCases) { level in
                    MyStyleLevelCard(
                        level: level,
                        isSelected: levelRaw == level.rawValue,
                        onTap: { levelRaw = level.rawValue }
                    )
                }
            }
        }
    }

    // MARK: Extracting state

    @ViewBuilder private var extractingView: some View {
        HStack(spacing: Sp.md) {
            ProgressView().controlSize(.small)
            Text("Analyzing your writing style…")
                .font(.bodyBase)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Sp.sm)
    }

    // MARK: Sample input state

    @ViewBuilder private var sampleInputView: some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            Text("Paste 5–10 things you've written — messages, emails, notes. Mix of contexts gives a richer card. Raw samples never leave your device.")
                .font(.bodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Text area with placeholder overlay
            ZStack(alignment: .topLeading) {
                TextEditor(text: $sampleText)
                    .font(.bodySmall)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 160)
                    .padding(6)

                if sampleText.isEmpty {
                    Text("Paste your writing here…")
                        .font(.bodySmall)
                        .foregroundStyle(.tertiary)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )

            // Footer: word count + actions
            HStack(spacing: Sp.sm) {
                Group {
                    if wordCount == 0 {
                        Text("Need \(StyleCardService.minWords) words minimum")
                    } else if wordCount < StyleCardService.minWords {
                        Text("\(wordCount) / \(StyleCardService.minWords) words")
                    } else {
                        Text("\(wordCount) words — ready")
                            .foregroundStyle(.green)
                    }
                }
                .font(.bodySmall)
                .foregroundStyle(wordCount >= StyleCardService.minWords ? .green : .secondary)

                Spacer()

                if let err = extractError {
                    Text(err)
                        .font(.bodySmall)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if hasCard {
                    Button("Cancel") {
                        showSampleInput = false
                        extractError = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.bodySmall)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                }

                Button("Extract my style") { doExtract() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canExtract)
            }
        }
    }

    // MARK: Extract action

    private func doExtract() {
        guard canExtract else { return }
        let text = sampleText
        isExtracting = true
        extractError = nil
        Task { @MainActor in
            do {
                let sample = StyleCardService.WritingSample(text: text, context: "mixed")
                try await StyleCardService.shared.extractCard(from: [sample])
                hasCard         = true
                cardWords       = StyleCardService.shared.cardWordCount
                showSampleInput = false
                sampleText      = ""
            } catch {
                extractError = error.localizedDescription
            }
            isExtracting = false
        }
    }
}

// MARK: - My Style Level Card
//
// One card per spectrum position (Raw You / Light You / Polished You / Best You).
// Teal accent to visually distinguish from the personality (accent) and cleanup
// (accent) rows. Same layout as CleanupCard — serif title, sans tagline, italic
// example bubble, selection border.

private struct MyStyleLevelCard: View {
    let level: MyStyleLevel
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    // Teal — distinct from personality (accent) and cleanup (accent) rows.
    private static let teal = Color(red: 0.22, green: 0.62, blue: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            VStack(alignment: .leading, spacing: Sp.xs) {
                Text(level.displayName)
                    .font(.serifSection)
                Text(level.tagline)
                    .font(.bodyBase)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)

            Text(level.example.after)
                .font(.sans(10, weight: .regular).italic())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Sp.sm)
                .padding(.vertical, Sp.xs)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Self.teal.opacity(0.10))
                )
        }
        .padding(Sp.lg)
        .frame(maxWidth: .infinity, minHeight: 165, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .fill(.regularMaterial)
        )
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: CardShape.corner)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CardShape.corner)
                .strokeBorder(
                    isSelected ? Self.teal.opacity(0.6) : Color.primary.opacity(0.06),
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

// MARK: - HotkeyRoleCard

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
                .fill(.regularMaterial)
        )
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: CardShape.corner)
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

// MARK: - Live Meeting Row

/// Shown at the top of the Meetings tab while a meeting capture is in progress.
/// Displays a pulsing red dot, "Recording now", elapsed time, and the
/// accumulating transcript text from 30-second Parakeet chunks.
private struct LiveMeetingRow: View {
    let transcript: [TranscriptSegment]
    let durationSeconds: Int
    /// Bundle ID of the meeting app driving the capture (Meet, Zoom, etc.).
    /// Mirrors `RecordingState.meetingSourceBundleID`. Nil when unknown.
    var sourceBundleID: String? = nil
    /// How many participants the Chrome extension has scraped, if any.
    /// Zero means "unknown" — we hide the count instead of saying "0 people".
    var participantCount: Int = 0

    @State private var pulsing: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Sp.md) {
            // Pulsing red stripe — matches the at-a-glance stripe family
            // used by saved-meeting rows so the live row reads as part of
            // the same list, not a foreign banner.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.red)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .opacity(pulsing ? 0.5 : 1.0)
                .animation(
                    .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                    value: pulsing
                )

            VStack(alignment: .leading, spacing: Sp.xxs) {
                HStack(alignment: .center, spacing: Sp.sm) {
                    Circle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 6, height: 6)
                        .scaleEffect(pulsing ? 1.25 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                            value: pulsing
                        )
                    Text("Recording now")
                        .font(.bodyMedium.weight(.semibold))
                    Spacer(minLength: Sp.sm)
                    Text(formatDuration(durationSeconds))
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // Meta line: "3 people · Google Meet" — only renders when
                // we actually have something to show, so partial info
                // (just an app name, or just a count) still reads cleanly.
                if !metaLineParts.isEmpty {
                    HStack(spacing: Sp.xs) {
                        ForEach(Array(metaLineParts.enumerated()), id: \.offset) { idx, part in
                            if idx > 0 { Text("·").foregroundStyle(.quaternary) }
                            Text(part)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                if transcript.isEmpty {
                    Text("Listening…")
                        .font(.bodySmall)
                        .foregroundStyle(.tertiary)
                        .italic()
                        .padding(.top, Sp.xxs)
                } else {
                    Text(transcript.map(\.text).joined(separator: " "))
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, Sp.xxs)
                }
            }
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.04))
        .onAppear { pulsing = true }
    }

    /// Source app + participant count, in display order. Filters empties so
    /// partial info still reads cleanly ("Google Meet" with no count).
    private var metaLineParts: [String] {
        var out: [String] = []
        if participantCount > 0 {
            out.append("\(participantCount) \(participantCount == 1 ? "person" : "people")")
        }
        if let label = sourceAppName(sourceBundleID) {
            out.append(label)
        }
        return out
    }

    /// Map known meeting-app bundle IDs to display names. Returns nil for
    /// unknown/nil IDs so we can hide the slot instead of guessing.
    private func sourceAppName(_ bundleID: String?) -> String? {
        guard let id = bundleID else { return nil }
        let names: [String: String] = [
            "com.google.meet": "Google Meet", "us.zoom.xos": "Zoom",
            "com.hnc.Discord": "Discord", "ru.keepcoder.Telegram": "Telegram",
            "com.tinyspeck.slackmacgap": "Slack", "com.apple.FaceTime": "FaceTime",
            "com.cisco.webex.meetings": "Webex", "net.whatsapp.WhatsApp": "WhatsApp",
            "com.microsoft.teams2": "Teams", "com.skype.skype": "Skype",
            "com.apple.iChat": "Messages",
        ]
        return names[id]
    }

    private func formatDuration(_ s: Int) -> String {
        // h:mm:ss when the call passes an hour, m:ss otherwise — matches
        // the saved meeting rows' duration formatting so the two read as
        // a single time format.
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - MeetingSummaryBlock

/// Renders the LLM-generated meeting summary — overview, key decisions,
/// action items, open questions. Compact, ordered by signal: overview
/// reads like a TL;DR, decisions are the "what we concluded", actions are
/// what someone owes, open questions are what's still pending.
///
/// Empty fields are skipped silently. If ALL four are empty, a single
/// "Summary unavailable" placeholder shows with an optional Re-transcribe
/// button so the user can retry.
struct MeetingSummaryBlock: View {
    let summary: MeetingSummary
    /// Optional handler so a row can react when the user ticks an action
    /// item — typically refetches the meeting and saves the updated summary
    /// with the `isCompleted` flag flipped.
    var onActionItemToggled: ((UUID, Bool) -> Void)? = nil
    /// Optional handler the parent row passes in. Used by the empty-summary
    /// fallback to offer a one-click "try again" path. When nil, the button
    /// is hidden.
    var onRetranscribe: (() -> Void)? = nil

    private var isOverviewEmpty: Bool {
        summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isCompletelyEmpty: Bool {
        isOverviewEmpty
            && summary.keyDecisions.isEmpty
            && summary.actionItems.isEmpty
            && summary.openQuestions.isEmpty
    }

    var body: some View {
        if isCompletelyEmpty {
            emptySummaryFallback
        } else {
            populatedSummary
        }
    }

    @ViewBuilder
    private var populatedSummary: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            // Overview reads as a prose paragraph at the top — slightly
            // brighter than section bodies because it carries the highest
            // information density per line.
            if !isOverviewEmpty {
                Text(summary.overview)
                    .font(.bodySmall)
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }

            if !summary.keyDecisions.isEmpty {
                summarySection(
                    title: "Decisions",
                    icon: "checkmark.seal.fill",
                    tint: Color(red: 0.20, green: 0.70, blue: 0.55),
                    items: summary.keyDecisions
                )
            }

            if !summary.actionItems.isEmpty {
                actionItemsSection(items: summary.actionItems)
            }

            if !summary.openQuestions.isEmpty {
                summarySection(
                    title: "Open questions",
                    icon: "questionmark.circle.fill",
                    tint: Color(red: 0.55, green: 0.45, blue: 0.95),
                    items: summary.openQuestions
                )
            }
        }
        .padding(.vertical, Sp.xs)
    }

    /// All-sections-empty fallback. The row still shows something useful
    /// (and gives the user a one-click "try again" path) instead of a
    /// blank-looking expanded card.
    @ViewBuilder
    private var emptySummaryFallback: some View {
        HStack(alignment: .top, spacing: Sp.sm) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary unavailable")
                    .font(.bodySmall.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("The transcript didn't produce a structured summary.")
                    .font(.badge)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Sp.sm)
            if let onRetranscribe {
                Button {
                    onRetranscribe()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Re-transcribe")
                    }
                    .font(.bodySmall.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Re-run the transcript and summary against the saved audio")
            }
        }
        .padding(Sp.sm)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
        .padding(.vertical, Sp.xs)
    }

    @ViewBuilder
    private func actionItemsSection(items: [ActionItem]) -> some View {
        let tint = Color(red: 0.95, green: 0.55, blue: 0.30)
        VStack(alignment: .leading, spacing: Sp.xs) {
            HStack(spacing: Sp.xs) {
                Image(systemName: "checklist")
                    .font(.badge)
                Text("ACTION ITEMS")
                    .font(.badge)
                    .tracking(0.6)
            }
            .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            onActionItemToggled?(item.id, !item.isCompleted)
                        } label: {
                            Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(item.isCompleted ? tint : .secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .help(item.isCompleted ? "Mark as not done" : "Mark as done")

                        // Text + assignee chip on the same baseline so each
                        // line reads as "Ship welcome screen designs · Priya"
                        // instead of breaking into a two-line block.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.text)
                                .font(.bodySmall)
                                .foregroundStyle(item.isCompleted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.primary.opacity(0.85)))
                                .strikethrough(item.isCompleted, color: Color.secondary.opacity(0.5))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let assignee = item.assignee, !assignee.isEmpty {
                                assigneeChip(assignee, tint: tint, dimmed: item.isCompleted)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Inline pill displaying who owns an action item.
    @ViewBuilder
    private func assigneeChip(_ name: String, tint: Color, dimmed: Bool) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(dimmed ? Color.secondary.opacity(0.6) : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(tint.opacity(dimmed ? 0.05 : 0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(dimmed ? 0.10 : 0.25), lineWidth: 0.5)
            )
    }

    /// Per-item icon repeats the section icon at a smaller size so a
    /// glance picks up the section type (checkmark = decision,
    /// question mark = open question) without scrolling back up to the
    /// header.
    @ViewBuilder
    private func summarySection(title: String, icon: String, tint: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Sp.xs) {
            HStack(spacing: Sp.xs) {
                Image(systemName: icon)
                    .font(.badge)
                Text(title.uppercased())
                    .font(.badge)
                    .tracking(0.6)
            }
            .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundStyle(tint.opacity(0.7))
                            .frame(width: 12, alignment: .leading)
                            .padding(.top, 2)
                        Text(item)
                            .font(.bodySmall)
                            .foregroundStyle(.primary.opacity(0.82))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - MeetingTranscriptView

/// Inline transcript viewer for an expanded meeting row. Renders segments
/// grouped by speaker (consecutive same-speaker segments merge into one
/// bubble), each speaker tinted with a stable color derived from their
/// label. Compact, scrollable, copyable.
struct MeetingTranscriptView: View {
    let segments: [TranscriptSegment]
    /// Meeting ID — used to look up + persist rename edits.
    var meetingId: UUID? = nil
    /// Called when the user clicks a speaker group. Receives the group's
    /// start time so the audio player can seek to that moment.
    var onSeekRequested: ((TimeInterval) -> Void)? = nil

    /// Speaker rename sheet state. When non-nil, the sheet is presented
    /// with this speaker's current label + speakerId pre-filled.
    @State private var renameTarget: RenameTarget? = nil

    private struct RenameTarget: Identifiable {
        let id = UUID()
        let speakerId: String?
        let currentName: String
    }

    /// Consecutive segments by the same speaker get fused into one bubble.
    /// Keeps the transcript readable when the diarizer assigns the same
    /// voice across 10 consecutive 30s windows.
    private struct SpeakerGroup: Identifiable {
        let id = UUID()
        let speaker: String
        let speakerId: String?
        let startTime: TimeInterval
        let text: String
    }

    private var groups: [SpeakerGroup] {
        var result: [SpeakerGroup] = []
        for seg in segments {
            let cleaned = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if let last = result.last,
               last.speaker == seg.speaker,
               last.speakerId == seg.speakerId {
                // Merge into the previous group.
                let merged = SpeakerGroup(
                    speaker: last.speaker,
                    speakerId: last.speakerId,
                    startTime: last.startTime,
                    text: last.text + " " + cleaned
                )
                result.removeLast()
                result.append(merged)
            } else {
                result.append(SpeakerGroup(
                    speaker: seg.speaker,
                    speakerId: seg.speakerId,
                    startTime: seg.startTime,
                    text: cleaned
                ))
            }
        }
        return result
    }

    /// Stable color per speaker label. Hash the speaker string and index
    /// into a curated palette so the same speaker always gets the same
    /// color, but adjacent speakers contrast clearly.
    private func tint(for speaker: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.55, green: 0.45, blue: 0.95), // indigo
            Color(red: 0.20, green: 0.70, blue: 0.55), // teal
            Color(red: 0.95, green: 0.55, blue: 0.30), // amber
            Color(red: 0.85, green: 0.40, blue: 0.55), // rose
            Color(red: 0.40, green: 0.65, blue: 0.90), // sky
            Color(red: 0.65, green: 0.55, blue: 0.35), // sand
            Color(red: 0.50, green: 0.80, blue: 0.40), // lime
        ]
        var hash: UInt = 5381
        for u in speaker.unicodeScalars { hash = (hash &* 33) &+ UInt(u.value) }
        return palette[Int(hash) % palette.count]
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        if mins >= 60 {
            let hrs = mins / 60
            let rem = mins % 60
            return String(format: "%d:%02d:%02d", hrs, rem, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.md) {
            ForEach(groups) { g in
                HStack(alignment: .top, spacing: Sp.sm) {
                    // Speaker badge — clicking the timestamp seeks audio.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.speaker)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint(for: g.speaker))
                            .lineLimit(1)
                            .frame(minWidth: 60, alignment: .leading)
                            .contextMenu {
                                Button("Rename \(g.speaker)…") {
                                    renameTarget = RenameTarget(
                                        speakerId: g.speakerId,
                                        currentName: g.speaker
                                    )
                                }
                            }
                        Button {
                            onSeekRequested?(g.startTime)
                        } label: {
                            Text(formatTimestamp(g.startTime))
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Jump to this point in the audio")
                    }
                    .frame(width: 70, alignment: .leading)
                    .padding(.top, 2)

                    Text(g.text)
                        .font(.bodySmall)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Tap on the body text also seeks (entire row clickable).
                        .contentShape(Rectangle())
                        .onTapGesture { onSeekRequested?(g.startTime) }
                }
            }
        }
    }
}

// MARK: - SegmentedGlassPicker
//
// Custom segmented control used inside the top toolbar. Reasons for a custom
// component instead of `Picker(.segmented)`:
//   1. Stock `.segmented` style doesn't accept a `.glassEffect` so the buttons
//      read as default macOS chrome rather than the macOS-26 glass language
//      used elsewhere in the window.
//   2. Stock segmented selection animates via a fade. We want the highlight
//      to *slide* between segments — `matchedGeometryEffect` does that for
//      free once you own the rendering.
//   3. We need a "primary" (larger) and "secondary" (smaller) flavor sharing
//      the same look so the toolbar's two pickers feel like one family.
//
// Selected: filled with `.regularMaterial` capsule (plus a faint accent tint)
// + a subtle elevated shadow. Unselected: transparent with secondary-label
// text that bumps to primary on hover. The whole strip is wrapped in a
// `.glassEffect(.regular.interactive(), in: Capsule())` so the track itself
// participates in the macOS-26 glass system and reacts to hover.
private struct SegmentedGlassPicker<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let label: KeyPath<Option, String>
    /// Primary controls (Dictations/Meetings) get larger type + horizontal
    /// padding. Secondary (List/Calendar) ride smaller so the toolbar reads
    /// as primary-with-context rather than two equal pickers.
    let isPrimary: Bool
    /// Shared namespace passed in from the parent so the selection indicator
    /// animates across segments even after the picker is rebuilt.
    let namespace: Namespace.ID
    /// Stable ID for `matchedGeometryEffect` — must be unique across the
    /// window. Two pickers in the same toolbar use different IDs.
    let geometryID: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options) { option in
                segmentButton(for: option)
            }
        }
        .padding(.horizontal, isPrimary ? 6 : 4)
        .padding(.vertical, isPrimary ? 4 : 3)
        .glassEffect(
            .regular.interactive(),
            in: Capsule(style: .continuous)
        )
        .overlay(
            // Hairline border keeps the capsule defined against the app shell
            // even when the glass effect is at its lightest (light mode).
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .fixedSize()
    }

    @ViewBuilder
    private func segmentButton(for option: Option) -> some View {
        let isSelected = option == selection
        let optionLabel = option[keyPath: label]

        Button {
            // Spring keeps the indicator's slide tactile rather than mushy.
            // Damping > 0.8 prevents overshoot inside a 36pt-tall toolbar.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                selection = option
            }
        } label: {
            Text(optionLabel)
                .font(isPrimary
                      ? .system(size: 12, weight: .semibold)
                      : .system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, isPrimary ? 12 : 10)
                .padding(.vertical, isPrimary ? 5 : 4)
                .background {
                    if isSelected {
                        // Filled selected pill — regularMaterial + a faint
                        // accent tint reads as "active" without competing
                        // with content in the body. `matchedGeometryEffect`
                        // is what makes the pill slide between segments.
                        Capsule(style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.10))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.10), radius: 3, x: 0, y: 1)
                            .matchedGeometryEffect(id: geometryID, in: namespace)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(optionLabel)
    }
}

// MARK: - Preview

#Preview {
    BigMenuWindow(recordingState: RecordingState())
}
