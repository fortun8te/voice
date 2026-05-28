// MeetingAudioPlayer.swift
// ============================================================
// Inline audio playback for a meeting row. Wraps AVAudioPlayer
// in an @Observable controller + a SwiftUI surface with:
//   • 15s back / play-pause / 15s forward (glassy circle for play)
//   • Scrub bar with hover tooltip + 1s drag snapping
//   • Speed menu (0.75 / 1.0 / 1.25 / 1.5 / 2.0)
//   • Click any transcript segment row → seek(to:)
//
// Background is transparent — the parent meeting row provides
// the card / context. The play/pause button is the only accented
// surface; everything else is muted secondary.
//
// While playing, the controller posts `.voiceAudioPlayerPosition`
// at the same 100ms tick that drives `currentTime`, so a
// transcript view rendered alongside can highlight the segment
// whose [startTime, endTime] window contains the cursor.
// ============================================================

import SwiftUI
import AVFoundation
import Observation

extension Notification.Name {
    /// Posted by `MeetingAudioPlayer` every ~100ms while playing, and once
    /// after every manual seek (even while paused). The `object` of the
    /// notification is the posting player instance, so listeners can scope
    /// to a particular player; `userInfo["time"]` carries the cursor
    /// timestamp as `TimeInterval`. Listened to by `MeetingTranscriptView`
    /// so it can highlight the segment whose [startTime, endTime] window
    /// contains the current cursor.
    static let voiceAudioPlayerPosition = Notification.Name("voice.audioPlayerPosition")
}

/// Process-wide coordinator that keeps at most one `MeetingAudioPlayer`
/// playing at a time. Each row owns its own `@State` player (so scrub state
/// and load cache survive collapse/expand), but as soon as one starts
/// playing it registers as the active one — and any other active player
/// pauses itself. This is the "only one meeting plays at a time" guarantee.
@MainActor
final class MeetingAudioCoordinator {
    static let shared = MeetingAudioCoordinator()
    private weak var active: MeetingAudioPlayer?

    func didStartPlaying(_ player: MeetingAudioPlayer) {
        if let other = active, other !== player {
            other.pauseSilently()
        }
        active = player
    }

    func didStopPlaying(_ player: MeetingAudioPlayer) {
        if active === player { active = nil }
    }
}

@Observable
@MainActor
final class MeetingAudioPlayer {
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    /// 0.75 / 1.0 / 1.25 / 1.5 / 2.0 — set by the speed menu. Survives reloads
    /// because it's reapplied to a fresh AVAudioPlayer in `load(_:)`.
    var playbackRate: Float = 1.0

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?
    /// The path the player is currently bound to, so swapping meetings
    /// (or re-opening the same one) doesn't pile up multiple players.
    private(set) var loadedPath: String?

    func load(_ url: URL) {
        // No-op if we're already on this file.
        if loadedPath == url.path, player != nil { return }
        stopTicker()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.enableRate = true
            p.rate = playbackRate
            player = p
            loadedPath = url.path
            duration = p.duration
            currentTime = 0
            isPlaying = false
        } catch {
            print("[VOICE-PLAYER] couldn't load \(url.lastPathComponent): \(error.localizedDescription)")
            player = nil
            loadedPath = nil
            duration = 0
            currentTime = 0
            isPlaying = false
        }
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTicker()
            MeetingAudioCoordinator.shared.didStopPlaying(self)
        } else {
            // Tell the coordinator first — it will pause any other player
            // currently playing before we start, so two rows can't overlap.
            MeetingAudioCoordinator.shared.didStartPlaying(self)
            player.play()
            // `rate` must be set AFTER `play()` — AVAudioPlayer resets rate
            // when transitioning from paused/stopped to playing.
            player.rate = playbackRate
            isPlaying = true
            startTicker()
        }
    }

    /// Pause without notifying the coordinator. Used by the coordinator
    /// itself when forcing other players to stop, and by the view when the
    /// owning row collapses. Safe to call when not playing — no-op.
    func pauseSilently() {
        guard let player, player.isPlaying else {
            isPlaying = false
            stopTicker()
            return
        }
        player.pause()
        isPlaying = false
        stopTicker()
    }

    /// Pause if playing, and also deregister from the coordinator. Used by
    /// the row when it collapses, so the next "play" press anywhere starts
    /// from a clean slate.
    func pauseIfPlaying() {
        if isPlaying { pauseSilently() }
        MeetingAudioCoordinator.shared.didStopPlaying(self)
    }

    /// Seek to `time` (seconds). If the player is currently playing, keeps
    /// playing from the new position. Otherwise stays paused and just moves
    /// the cursor — caller can then call togglePlay().
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, player.duration))
        player.currentTime = clamped
        currentTime = clamped
        // Post immediately so the transcript view can re-highlight even when
        // we're paused — the periodic ticker only fires while playing.
        postPositionNotification()
    }

    /// Jump forward/back by `delta` seconds, clamped to [0, duration].
    /// Used by the 15s skip buttons.
    func skip(by delta: TimeInterval) {
        let target = currentTime + delta
        seek(to: target)
    }

    /// Set the playback rate directly. Replaces the older "cycle" gesture
    /// with a menu so users can pick from the canonical 5-stop preset.
    func setSpeed(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
    }

    private func startTicker() {
        stopTicker()
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let player = self.player else { return }
                self.currentTime = player.currentTime
                self.postPositionNotification()
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTicker()
                    // Track ended naturally — release the coordinator slot
                    // so another row's play press isn't surprised by us.
                    MeetingAudioCoordinator.shared.didStopPlaying(self)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTicker() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Broadcast the current cursor so a sibling transcript view can
    /// highlight the active segment. Sent on every tick (~100ms) plus
    /// every manual seek, even when paused — so scrubbing while stopped
    /// still moves the highlight. The `object` is `self` so listeners
    /// can scope by player identity; `userInfo["time"]` carries the cursor.
    private func postPositionNotification() {
        NotificationCenter.default.post(
            name: .voiceAudioPlayerPosition,
            object: self,
            userInfo: ["time": currentTime]
        )
    }

    // deinit removed — MainActor isolation prevents touching `tickTimer` here.
    // The timer is invalidated in `stopTicker()` which is called on every
    // pause/seek and when the player loads a new file. Stale timers won't
    // outlive the instance because the closure captures `[weak self]`.
}

// MARK: - SwiftUI surface

/// Inline player UI — three transport buttons (back 15s / play-pause / forward 15s),
/// a scrub bar with hover tooltip, a time stamp, and a speed chip menu beneath.
/// Background is transparent so the parent row provides context.
struct MeetingAudioPlayerBar: View {
    @Bindable var player: MeetingAudioPlayer

    /// The canonical speed presets the menu offers.
    private static let speedPresets: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.xs) {
            // Transport row: scrubber on the left grows to fill, controls on
            // the right are fixed-width so the bar doesn't shift as the time
            // string changes length.
            HStack(spacing: Sp.sm) {
                // Scrub bar — fills available horizontal space.
                ScrubBar(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    total: player.duration
                )

                // Time stamp: current / total. Monospaced so digits don't dance.
                Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 88, alignment: .trailing)
                    .monospacedDigit()

                // Transport cluster — back 15s, play/pause, forward 15s.
                HStack(spacing: 6) {
                    SkipButton(
                        symbol: "gobackward.15",
                        accessibilityLabel: "Back 15 seconds"
                    ) {
                        player.skip(by: -15)
                    }
                    .disabled(player.duration <= 0)

                    PlayPauseButton(isPlaying: player.isPlaying) {
                        player.togglePlay()
                    }
                    .disabled(player.duration <= 0)

                    SkipButton(
                        symbol: "goforward.15",
                        accessibilityLabel: "Forward 15 seconds"
                    ) {
                        player.skip(by: 15)
                    }
                    .disabled(player.duration <= 0)
                }
            }

            // Speed chip — small, below the controls, aligned right to sit
            // under the transport cluster.
            HStack {
                Spacer()
                SpeedChip(
                    current: player.playbackRate,
                    presets: Self.speedPresets,
                    onSelect: { player.setSpeed($0) }
                )
            }
        }
        .padding(.vertical, 2)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, !t.isNaN else { return "0:00" }
        let total = max(0, Int(t))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Buttons

/// 32pt glass circle with `play.fill` / `pause.fill` centered at 14pt.
/// Uses `.glassEffect(.regular.interactive(), in: Circle())` so it feels
/// native on macOS 26 — the only accented control in the bar.
private struct PlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The fill colour is the accent; the glass is what makes it feel
            // "alive" — pressing it bends the surface a little.
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.85))
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    // Visually centre `play.fill` — its glyph hangs left.
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: 32, height: 32)
            .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(isPlaying ? "Pause" : "Play")
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// 28pt secondary transport button — used for ±15s skip.
/// Subtle (no glass, no accent) so the play/pause stays the focal point.
private struct SkipButton: View {
    let symbol: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isHovering ? Color.primary.opacity(0.85) : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Compact "1×" chip that opens a Menu with the canonical speed presets.
/// The checkmark next to the currently selected speed makes it scannable
/// without needing the chip itself to display the active value with emphasis.
private struct SpeedChip: View {
    let current: Float
    let presets: [Float]
    let onSelect: (Float) -> Void
    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(presets, id: \.self) { rate in
                Button {
                    onSelect(rate)
                } label: {
                    HStack {
                        Text(Self.format(rate))
                        if abs(rate - current) < 0.001 {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(Self.format(current))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(isHovering ? Color.primary.opacity(0.85) : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Playback speed")
        .accessibilityLabel("Playback speed: \(Self.format(current))")
    }

    /// Drop the `.0` on whole numbers ("1×" not "1.0×") but keep the decimal
    /// on fractional speeds ("0.75×", "1.25×").
    static func format(_ rate: Float) -> String {
        let rounded = (rate * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(format: "%.0f×", rounded)
        }
        return String(format: "%g×", rounded)
    }
}

// MARK: - Scrub bar

/// Horizontal scrub bar with a draggable thumb. Hovering shows a small
/// time tooltip at the cursor X; dragging snaps to whole-second increments
/// so fine corrections don't fight floating-point jitter.
private struct ScrubBar: View {
    @Binding var value: TimeInterval
    let total: TimeInterval

    @State private var isDragging = false
    /// Local hover X (in scrub-bar coordinates) — drives the tooltip position.
    /// Nil when the mouse isn't over the bar.
    @State private var hoverX: CGFloat? = nil
    /// While the user is dragging we route the tooltip to the drag location
    /// instead of the hover location, so the tooltip stays glued to the thumb.
    @State private var dragX: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 3)

                // Progress
                Capsule()
                    .fill(Color.accentColor.opacity(isDragging ? 1.0 : 0.85))
                    .frame(width: progressWidth(in: geo.size.width), height: 3)

                // Thumb — visible always, grows on drag.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: isDragging ? 11 : 8, height: isDragging ? 11 : 8)
                    .offset(
                        x: progressWidth(in: geo.size.width) - (isDragging ? 5.5 : 4)
                    )
                    .shadow(color: .black.opacity(0.20), radius: 2, y: 1)

                // Hover tooltip — anchored to the current pointer / drag X.
                // Drawn last so it renders above the thumb.
                if let tooltipX = tooltipAnchorX(in: geo.size.width), total > 0 {
                    let t = max(0, min(total, total * Double(tooltipX / geo.size.width)))
                    TimeTooltip(text: Self.formatTooltipTime(t))
                        .position(x: tooltipX, y: -10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let clampedX = max(0, min(geo.size.width, g.location.x))
                        dragX = clampedX
                        let frac = clampedX / max(1, geo.size.width)
                        let raw = frac * total
                        // Snap to 1-second increments so the cursor lands on
                        // clean integers — feels more deliberate than letting
                        // the bar emit fractional jitter from sub-pixel drag.
                        let snapped = (raw).rounded()
                        value = max(0, min(total, snapped))
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragX = nil
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverX = max(0, min(geo.size.width, location.x))
                case .ended:
                    hoverX = nil
                }
            }
            .animation(.easeOut(duration: 0.12), value: isDragging)
            .animation(.easeOut(duration: 0.10), value: hoverX != nil)
        }
        .frame(height: 22)
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let frac = max(0, min(1, value / total))
        return totalWidth * frac
    }

    /// Where to anchor the tooltip. Drag wins over hover so the tooltip
    /// stays pinned to the thumb during a drag even if the cursor strays.
    private func tooltipAnchorX(in totalWidth: CGFloat) -> CGFloat? {
        if let dragX { return dragX }
        if let hoverX { return hoverX }
        return nil
    }

    /// Same format the bar uses for the main timestamp, but always
    /// includes minutes so brief moments still read as "0:07".
    static func formatTooltipTime(_ t: TimeInterval) -> String {
        guard t.isFinite, !t.isNaN else { return "0:00" }
        let total = max(0, Int(t.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Small pill-shaped tooltip used by the scrubber on hover/drag.
private struct TimeTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(.regularMaterial)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .fixedSize()
    }
}
