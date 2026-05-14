// LaunchAtLoginService.swift
// ============================================================
// Thin wrapper around SMAppService.mainApp (macOS 13+) that
// keeps the AppStorage("launchAtLogin") flag in sync with the
// real system state. Anywhere in the app you can flip the
// toggle and the OS registration follows.
//
// Public API:
//   LaunchAtLoginService.isEnabled      -> Bool
//   LaunchAtLoginService.setEnabled(_:) -> Void
//   LaunchAtLoginService.syncFromStorage() -> Void
//
// Notes:
// - Uses SMAppService.mainApp.status to read current state, so
//   even if the user toggled it from System Settings, we reflect
//   reality on next launch.
// - Failures are logged via Telemetry and never throw to the
//   caller — launch-at-login is a nice-to-have, not load-bearing.
// ============================================================

import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLoginService {

    private static let storageKey = "launchAtLogin"

    /// Reads from SMAppService — the source of truth.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Register or unregister the main app for login.
    /// Persists the user's intent in AppStorage as well.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: storageKey)

        guard #available(macOS 13.0, *) else {
            Telemetry.log("launch_at_login.unsupported_os")
            return false
        }

        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                    Telemetry.log("launch_at_login.registered")
                }
            } else {
                if service.status != .notRegistered {
                    try service.unregister()
                    Telemetry.log("launch_at_login.unregistered")
                }
            }
            return true
        } catch {
            Telemetry.log("launch_at_login.error", properties: [
                "intent": enabled ? "enable" : "disable",
                "error": "\(error)"
            ])
            NotificationCenter.default.post(
                name: .voiceError,
                object: nil,
                userInfo: ["message": "Couldn't update Launch at Login: \(error.localizedDescription)"]
            )
            return false
        }
    }

    /// Called on launch — reconcile user's stored intent with reality.
    /// If the user wanted launch-at-login but the system says it's not
    /// registered (e.g. they reinstalled the app), re-register silently.
    static func syncFromStorage() {
        guard #available(macOS 13.0, *) else { return }
        // First launch: default to ON. User can disable from menu.
        guard UserDefaults.standard.object(forKey: storageKey) != nil else {
            setEnabled(true)
            return
        }
        let want = UserDefaults.standard.bool(forKey: storageKey)
        let have = SMAppService.mainApp.status == .enabled
        if want != have {
            _ = setEnabled(want)
        }
    }
}
