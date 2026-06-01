// CallAppDetector.swift
// Detects when a known native call app (Discord, Zoom, MS Teams, Slack
// huddles, FaceTime, WhatsApp, Telegram) is in an active call.
//
// Detection strategy (event-driven, not polling):
//   • NSWorkspace notifications fire instantly when any app activates,
//     launches, or terminates — no CPU cost at idle.
//   • A lightweight 30s fallback poll catches edge cases such as a call app
//     gaining/losing the mic without an app-activation event.
//   • This detector NEVER touches ScreenCaptureKit. It relies solely on
//     non-screen signals (NSWorkspace running applications, frontmost bundle
//     id, and the mic-in-use probe), so it cannot light the macOS
//     screen-recording indicator. Browser-tab call detection (e.g. Google
//     Meet in a tab) degrades gracefully — it is no longer detected here;
//     native desktop call apps (Zoom/Teams/Discord/etc.) still are.
//
// Heuristic per evaluation:
//   active(app) == (bundleID in knownCallApps)
//               && (app is running, via NSRunningApplication)
//               && (default input device is in use by some process)
//               && (app is frontmost)
//
// Grace periods debounce the signal:
//   - 2 consecutive positive evaluations before firing active=true
//   - 6 consecutive negative evaluations before firing active=false
//   (With notifications each evaluation is triggered by a real event, so
//    grace still protects against brief false positives from audio pings.)
//
// Lifecycle:
//   let det = CallAppDetector()
//   det.onCallStateChange = { active, bundleID in ... }
//   det.start()    // subscribes to workspace notifications + starts 30s fallback
//   det.stop()     // tears down observers and timer

import Foundation
import AppKit

@MainActor
final class CallAppDetector {

    // MARK: - Public API

    /// Fires whenever the detector's debounced call-active state flips.
    /// `(active, bundleID)` — bundleID is non-nil when active=true, nil on stop.
    var onCallStateChange: ((Bool, String?) -> Void)?

    /// Bundle IDs that count as "native call apps" mapped to a friendly name.
    static let knownCallApps: [String: String] = [
        "com.hnc.Discord": "Discord",
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "desktop.WhatsApp": "WhatsApp",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "ru.keepcoder.Telegram": "Telegram"
    ]

    // MARK: - State

    /// Fallback poll timer — fires every 30s to catch browser tab switches.
    private var fallbackTimer: Timer?
    private let fallbackInterval: TimeInterval = 30.0

    /// NSWorkspace notification observers (held to allow removal on stop).
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Number of consecutive positive evaluations required to fire active=true.
    private let startGraceTicks = 2
    /// Number of consecutive negative evaluations required to fire active=false.
    private let stopGraceTicks = 6

    /// Per-bundle consecutive-positive counter.
    private var positiveStreak: [String: Int] = [:]
    /// Per-bundle consecutive-negative counter.
    private var negativeStreak: [String: Int] = [:]

    /// The bundle we currently consider "in a call" (after start-grace).
    private(set) var currentActiveBundle: String?

    // MARK: - Lifecycle

    func start() {
        guard workspaceObservers.isEmpty && fallbackTimer == nil else { return }

        let nc = NSWorkspace.shared.notificationCenter

        // App activated (user switches to a different app).
        let activateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor [weak self] in
                await self?.tick(triggeredBy: app?.bundleIdentifier)
            }
        }

        // New app launched — may be a meeting app starting up.
        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            // Only care if it's one of our known apps.
            guard let bundle = app?.bundleIdentifier,
                  Self.knownCallApps.keys.contains(bundle) else { return }
            Task { @MainActor [weak self] in
                await self?.tick(triggeredBy: bundle)
            }
        }

        // App terminated — if it was the active call app, end the call immediately.
        let terminateObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard let bundle = app?.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                await self?.handleAppTerminated(bundle: bundle)
            }
        }

        workspaceObservers = [activateObs, launchObs, terminateObs]

        // 30s fallback poll — catches browser tab switches to Meet/Teams web
        // where the frontmost app bundle never changes.
        let timer = Timer.scheduledTimer(withTimeInterval: fallbackInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick(triggeredBy: nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer

        // Run one immediate evaluation for a fast first reading.
        Task { @MainActor [weak self] in
            await self?.tick(triggeredBy: nil)
        }

        print("[CallAppDetector] started — event-driven + \(Int(fallbackInterval))s fallback poll")
    }

    func stop() {
        // Remove workspace notification observers.
        let nc = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers { nc.removeObserver(obs) }
        workspaceObservers.removeAll()

        // Invalidate fallback timer.
        fallbackTimer?.invalidate()
        fallbackTimer = nil

        // Reset state.
        positiveStreak.removeAll()
        negativeStreak.removeAll()
        if let bundle = currentActiveBundle {
            currentActiveBundle = nil
            onCallStateChange?(false, bundle)
        }
        print("[CallAppDetector] stopped")
    }

    // MARK: - Evaluation

    /// Main evaluation entry-point. `triggeredBy` is the bundle ID of the app
    /// that caused this evaluation (kept for call-site compatibility / logging).
    private func tick(triggeredBy triggerBundle: String?) async {
        // 1. Determine which known call-app bundles are actually running right now.
        //    Use NSRunningApplication — zero cost, no WindowServer query, and no
        //    ScreenCaptureKit (which would light the screen-recording indicator).
        let runningBundles: Set<String> = Set(
            NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier }
                .filter { Self.knownCallApps.keys.contains($0) }
        )

        // 2. Frontmost bundle.
        let frontmostBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // 3. Mic-in-use flag.
        let micInUse = MicActivityProbe.isDefaultInputInUse()

        // 4. Update per-bundle streak counters.
        //    "Running" is determined purely from NSRunningApplication — we never
        //    query ScreenCaptureKit, so browser-tab calls (Google Meet in a tab)
        //    are intentionally not detected here. Native desktop call apps are.
        for bundle in Self.knownCallApps.keys {
            let appRunning = runningBundles.contains(bundle)

            let candidate = appRunning
                && micInUse
                && frontmostBundle == bundle

            if candidate {
                positiveStreak[bundle, default: 0] += 1
                negativeStreak[bundle] = 0
            } else {
                negativeStreak[bundle, default: 0] += 1
                positiveStreak[bundle] = 0
            }
        }

        // 5. Decide transitions.
        if let active = currentActiveBundle {
            let negCount = negativeStreak[active] ?? 0
            if negCount >= stopGraceTicks {
                print("[CallAppDetector] \(active) call ended (negative streak \(negCount))")
                currentActiveBundle = nil
                positiveStreak[active] = 0
                negativeStreak[active] = 0
                onCallStateChange?(false, active)
            }
        } else {
            let candidates = positiveStreak
                .filter { $0.value >= startGraceTicks }
                .sorted { $0.value > $1.value }
            if let chosen = candidates.first?.key {
                print("[CallAppDetector] \(chosen) call detected (positive streak \(positiveStreak[chosen] ?? 0))")
                currentActiveBundle = chosen
                negativeStreak[chosen] = 0
                onCallStateChange?(true, chosen)
            }
        }
    }

    /// Called immediately when a known app terminates. If it was the active call
    /// app, fire inactive without waiting for the negative-streak grace period.
    private func handleAppTerminated(bundle: String) async {
        guard Self.knownCallApps.keys.contains(bundle) else { return }

        // Reset its streaks.
        positiveStreak[bundle] = 0
        negativeStreak[bundle] = 0

        // If it was the active call app, end the call right now.
        if currentActiveBundle == bundle {
            print("[CallAppDetector] \(bundle) terminated — ending call immediately")
            currentActiveBundle = nil
            onCallStateChange?(false, bundle)
        }
    }
}
