// VOICE — Menu Popup (rewritten)
// ============================================================
// Single cohesive popup. No sidebar, no separate Quick Copy menu,
// no duplicate status. Layout top to bottom:
//
//   TOP BAR       — "VOICE" wordmark + live status pill
//   PIPELINE      — what happened in the last dictation (collapsible)
//   RECENT        — last 5 dictations, scrollable, copy-on-click
//   BOTTOM BAR    — Polish toggle + Launch at Login + Settings
//
// Settings open as a sheet over this view.
// ============================================================

import SwiftUI
import AppKit
import AVFoundation

// MARK: - Spacing tokens

private enum Sp {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 24
}

// MARK: - Root view

struct BigMenuWindow: View {
    @Bindable var recordingState: RecordingState

    @State private var showSettings = false
    // Pipeline section is visible after a dictation lands; auto-hides after 20s of
    // no new activity. `pipelineVisible` stays true if user manually expanded.
    @State private var pipelineVisible = false
    @State private var pipelineAutoHideTask: Task<Void, Never>? = nil
    @State private var pipelineExpanded = false   // per-stage expand

    @AppStorage("llmPolishEnabled") private var polishEnabled: Bool = LLMPolisher.isAvailable
    @AppStorage("launchAtLogin")    private var launchAtLogin: Bool = false

    // Tick from recordingState drives re-render when new dictation lands.
    private var recents: [RecentDictation] { RecentDictations.all() }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            // Pipeline — only if there's data to show
            if pipelineVisible, let recent = recents.first {
                pipelineSection(recent: recent)
                Divider()
            }

            recentSection
            Divider()
            bottomBar
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $showSettings) {
            SettingsSheet(recordingState: recordingState)
        }
        .onChange(of: recordingState.recentDictationsTick) { _, _ in
            showPipelineWithAutoHide()
        }
        .onAppear {
            // Show pipeline on open if there's recent data and we just finished
            if !recents.isEmpty {
                pipelineVisible = true
                schedulePipelineAutoHide()
            }
            launchAtLogin = LaunchAtLoginService.isEnabled
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Sp.sm) {
            Text("VOICE")
                .font(.serif(13))
                .foregroundStyle(.tertiary)
                .tracking(1.2)

            Spacer()

            statusPill
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.md)
    }

    @ViewBuilder
    private var statusPill: some View {
        let (label, color, icon) = pillContent
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.sans(11, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Sp.sm)
        .padding(.vertical, Sp.xs)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.10))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(color.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    private var pillContent: (String, Color, String?) {
        if recordingState.isRecording {
            let s = recordingState.elapsedSeconds
            let dur = s < 60 ? "\(s)s" : "\(s/60)m \(s%60)s"
            return ("Recording · \(dur)", .red, "circle.fill")
        }
        if recordingState.isLocked {
            return ("Locked", .orange, "lock.fill")
        }
        if recordingState.isTranscribing {
            return ("Transcribing…", .blue, nil)
        }
        if !recents.isEmpty {
            let last = recents[0]
            let secs = Int(Date().timeIntervalSince(last.timestamp))
            let ago = secs < 60 ? "just now"
                    : secs < 3600 ? "\(secs/60)m ago"
                    : "\(secs/3600)h ago"
            return ("Done · \(ago)", .green, "checkmark")
        }
        return ("Ready", Color.secondary, nil)
    }

    // MARK: - Pipeline section

    @ViewBuilder
    private func pipelineSection(recent: RecentDictation) -> some View {
        let raw = recent.rawText
        let polishChanged = recent.hasPolishDiff
        let polishStatus = Qwen3Polisher.availabilityStatus

        // Outcome label for the polish stage when no changes were made
        let polishOutcomeNote: String = !polishEnabled ? "Off"
            : !polishStatus.isReady ? "Loading…"
            : "No improvements"

        // "Pasted to" app name from bundle ID
        let pasteAppName: String? = recent.pasteTargetBundleID.flatMap { bid in
            NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.localizedName
            ?? bid.split(separator: ".").last.map(String.init)
        }

        VStack(alignment: .leading, spacing: Sp.sm) {
            // Header row
            HStack {
                Text("Last dictation")
                    .font(.sans(9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                // Pasted-to badge
                if let appName = pasteAppName {
                    HStack(spacing: Sp.xs) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 8, weight: .medium))
                        Text(appName)
                            .font(.sans(9, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { pipelineVisible = false }}) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.quaternary)
                        .padding(.leading, Sp.xs)
                }
                .buttonStyle(.plain)
            }

            // Stage 1: Transcribed (raw or final if no raw)
            pipelineRow(
                icon: "mic.fill",
                label: "Transcribed",
                content: raw ?? recent.text,
                accent: Color.secondary,
                isMuted: false
            )

            // Stage 2: Polish — unified template
            if let raw, polishChanged {
                pipelineRow(
                    icon: "wand.and.sparkles",
                    label: "Polished",
                    content: recent.text,
                    accent: Color.accentColor,
                    isMuted: false
                )
            } else {
                pipelineRow(
                    icon: "wand.and.sparkles",
                    label: "Polished",
                    content: nil,
                    accent: Color.secondary,
                    isMuted: true,
                    note: (raw == nil ? "Off" : polishOutcomeNote)
                )
            }
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.03))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.12)) { pipelineExpanded.toggle() }
            extendPipelineAutoHide()
        }
    }

    @ViewBuilder
    private func pipelineRow(
        icon: String,
        label: String,
        content: String?,
        accent: Color,
        isMuted: Bool,
        note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Sp.xs) {
            // Label row — unified for both muted and active states
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isMuted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(accent.opacity(0.8)))
                Text(label)
                    .font(.sans(10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(isMuted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(accent.opacity(0.8)))
                if let note {
                    Text("—")
                        .font(.sans(10))
                        .foregroundStyle(.quaternary)
                    Text(note)
                        .font(.sans(10))
                        .foregroundStyle(.quaternary)
                }
            }

            // Content text — only when content is present
            if let content {
                Text(content)
                    .font(.sans(12))
                    .tracking(LetterSpacing.body)
                    .foregroundStyle(.primary)
                    .lineLimit(pipelineExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Sp.md)
        .padding(.vertical, Sp.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isMuted
                    ? Color(nsColor: .controlBackgroundColor).opacity(0.25)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - Recent dictations

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recents.isEmpty {
                emptyRecent
            } else {
                ForEach(Array(recents.prefix(5).enumerated()), id: \.element.id) { idx, item in
                    RecentRow(item: item, isLast: idx == min(4, recents.count - 1))
                }
            }
        }
    }

    @ViewBuilder
    private var emptyRecent: some View {
        HStack(spacing: Sp.sm) {
            Image(systemName: "waveform")
                .font(.system(size: 13))
                .foregroundStyle(.quaternary)
            VStack(alignment: .leading, spacing: Sp.xs) {
                Text("No dictations yet")
                    .font(.sans(13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Hold the hotkey to record")
                    .font(.sans(11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Sp.md) {
            // Polish toggle — lightweight inline
            polishToggle

            Spacer()

            // Launch at Login — small icon toggle
            Button(action: {
                let next = !LaunchAtLoginService.isEnabled
                _ = LaunchAtLoginService.setEnabled(next)
                launchAtLogin = LaunchAtLoginService.isEnabled
            }) {
                Image(systemName: launchAtLogin ? "arrow.up.circle.fill" : "arrow.up.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(launchAtLogin ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(launchAtLogin ? "Launch at Login: ON" : "Launch at Login: OFF")

            // Settings
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.md)
    }

    @ViewBuilder
    private var polishToggle: some View {
        let status = Qwen3Polisher.availabilityStatus
        let isOn = polishEnabled && status.isReady

        Button(action: {
            guard status.isReady else { return }
            polishEnabled.toggle()
        }) {
            HStack(spacing: Sp.sm) {
                // Animated switch pill — same visual weight as the Launch at Login button
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: 28, height: 16)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: isOn ? 6 : -6)
                        .animation(.easeInOut(duration: 0.15), value: isOn)
                }
                Text("Polish")
                    .font(.sans(12, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!status.isReady)
        .help(status.isReady ? "Toggle on-device polish" : "Polish model: \(status.displayLabel)")
        .animation(.easeOut(duration: 0.1), value: isOn)
    }

    // MARK: - Helpers

    private func showPipelineWithAutoHide() {
        pipelineVisible = true
        pipelineExpanded = false
        schedulePipelineAutoHide()
    }

    private func schedulePipelineAutoHide() {
        pipelineAutoHideTask?.cancel()
        pipelineAutoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { pipelineVisible = false }
        }
    }

    /// Extend the auto-hide timer by 15 more seconds when the user interacts
    /// with the pipeline section (tap to expand/collapse).
    private func extendPipelineAutoHide() {
        pipelineAutoHideTask?.cancel()
        pipelineAutoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { pipelineVisible = false }
        }
    }
}

// MARK: - Recent row

private struct RecentRow: View {
    let item: RecentDictation
    let isLast: Bool

    @State private var hovering = false
    @State private var copied = false

    private var preview: String {
        let clean = item.text.replacingOccurrences(of: "\n", with: " ")
        let s = String(clean.prefix(72))
        return clean.count > 72 ? s + "…" : s
    }

    private var timestamp: String {
        let secs = Int(Date().timeIntervalSince(item.timestamp))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    var body: some View {
        Button(action: copyText) {
            HStack(spacing: Sp.sm) {
                // Preview + timestamp on same line, timestamp right-aligned
                HStack(alignment: .firstTextBaseline, spacing: Sp.xs) {
                    Text(preview)
                        .font(.sans(12))
                        .tracking(LetterSpacing.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(timestamp)
                        .font(.sans(10))
                        .tracking(LetterSpacing.body)
                        .foregroundStyle(.quaternary)
                        .fixedSize()
                }

                // Copy indicator — visible on hover or when just copied
                Group {
                    if copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 16)
                .opacity(hovering || copied ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: hovering)
                .animation(.easeOut(duration: 0.12), value: copied)
            }
            .padding(.horizontal, Sp.xl)
            .padding(.vertical, Sp.md)
            .background(hovering ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    .frame(height: 0.5)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.08), value: hovering)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { copied = false }
    }
}

// MARK: - Settings sheet

private struct SettingsSheet: View {
    @Bindable var recordingState: RecordingState
    @Environment(\.dismiss) private var dismiss

    @AppStorage("hotkey")           private var hotkey: String = HotkeyOption.rightOption.rawValue
    @AppStorage("autoPaste")        private var autoPaste: Bool = true
    @AppStorage("autoCopy")         private var autoCopy: Bool = true
    @AppStorage("soundEffectsEnabled") private var soundEffects: Bool = true
    @AppStorage("llmPolishEnabled") private var polishEnabled: Bool = LLMPolisher.isAvailable

    @State private var micGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axGranted: Bool = AXIsProcessTrusted()
    @State private var refreshTimer: Timer?

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
            // Header
            HStack {
                Text("Settings")
                    .font(.sans(16, weight: .semibold))
                    .tracking(-0.2)
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
                    section("Hotkey") {
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

                    section("Output") {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            toggle("Paste automatically", isOn: $autoPaste)
                            toggle("Copy to clipboard", isOn: $autoCopy)
                            toggle("Sound effects", isOn: $soundEffects)
                            VStack(alignment: .leading, spacing: Sp.xs) {
                                toggle("Smart corrections", isOn: $polishEnabled)
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(polishStatusColor)
                                        .frame(width: 6, height: 6)
                                    Text("Status: \(Qwen3Polisher.availabilityStatus.displayLabel)")
                                        .font(.sans(11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, Sp.xl)
                            }
                        }
                    }

                    Divider()

                    section("Permissions") {
                        VStack(alignment: .leading, spacing: Sp.sm) {
                            permissionRow("Microphone", granted: micGranted) {
                                openPane("Privacy_Microphone")
                            }
                            permissionRow("Accessibility", granted: axGranted) {
                                openPane("Privacy_Accessibility")
                            }
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("VOICE \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.sans(11))
                    .foregroundStyle(.quaternary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Sp.xl)
            .padding(.vertical, Sp.md)
        }
        .frame(width: 320)
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
    private func section<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Sp.sm) {
            Text(label.uppercased())
                .font(.sans(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(.horizontal, Sp.xl)
        .padding(.vertical, Sp.md)
    }

    @ViewBuilder
    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
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
                .font(.sans(13))
                .tracking(LetterSpacing.body)
                .foregroundStyle(.primary)
            Spacer()
            if !granted {
                Button("Grant", action: action)
                    .buttonStyle(.borderless)
                    .font(.sans(11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .controlSize(.small)
            } else {
                Text("Granted")
                    .font(.sans(11))
                    .foregroundStyle(.tertiary)
            }
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

// MARK: - Int formatting helper (kept for compatibility)

fileprivate extension Int {
    func compactKilo() -> String {
        if self < 1_000 { return "\(self)" }
        if self < 10_000 { return String(format: "%.1fk", Double(self) / 1_000) }
        if self < 1_000_000 { return "\(self / 1_000)k" }
        return String(format: "%.1fM", Double(self) / 1_000_000)
    }
}

// MARK: - Preview

#Preview {
    BigMenuWindow(recordingState: RecordingState())
}
