// UpdateChecker.swift
// ============================================================
// Lightweight version checker. Pings a static version.json,
// compares to CFBundleShortVersionString, and fires a closure
// if an upgrade is available.
//
// Debounced to once per 24h via UserDefaults.
//
// Public API:
//   UpdateChecker.checkInBackground(onUpdateAvailable: { info in ... })
//
// version.json shape:
//   { "version": "1.2.0", "url": "https://voice.app/download" }
//
// If `feedURL` is empty, returns immediately — useful while the
// download URL is not yet provisioned.
// ============================================================

import Foundation

struct UpdateInfo {
    let version: String
    let downloadURL: URL?
}

enum UpdateChecker {

    /// Set this when the download URL is ready. Empty = no-op.
    private static let feedURL: URL? = nil
    // Example: URL(string: "https://voice.app/version.json")

    private static let lastCheckKey = "updateChecker.lastCheck"
    private static let interval: TimeInterval = 24 * 60 * 60  // 24h

    /// Fire-and-forget background check. Idempotent: skips if last
    /// check was within 24h. Calls `onUpdateAvailable` on the main
    /// actor when a newer version is found.
    static func checkInBackground(
        onUpdateAvailable: @escaping @MainActor (UpdateInfo) -> Void
    ) {
        guard let feedURL else {
            // No feed configured — skip silently. Don't log; this is
            // expected during early development.
            return
        }

        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let now = Date().timeIntervalSince1970
        if now - last < interval { return }

        Task.detached(priority: .background) {
            do {
                let (data, _) = try await URLSession.shared.data(from: feedURL)
                UserDefaults.standard.set(now, forKey: lastCheckKey)

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let remoteVersion = json["version"] as? String else {
                    Telemetry.log("update_check.bad_response")
                    return
                }
                let remoteURL = (json["url"] as? String).flatMap(URL.init(string:))

                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                if compareVersions(remote: remoteVersion, current: current) == .orderedDescending {
                    Telemetry.log("update_check.update_available", properties: [
                        "current": current,
                        "remote": remoteVersion
                    ])
                    let info = UpdateInfo(version: remoteVersion, downloadURL: remoteURL)
                    await MainActor.run { onUpdateAvailable(info) }
                } else {
                    Telemetry.log("update_check.up_to_date", properties: [
                        "current": current,
                        "remote": remoteVersion
                    ])
                }
            } catch {
                Telemetry.log("update_check.error", properties: ["error": "\(error)"])
            }
        }
    }

    /// Naive semver comparison: split on "." and compare ints.
    /// Non-numeric segments fall back to string comparison.
    private static func compareVersions(remote: String, current: String) -> ComparisonResult {
        let r = remote.split(separator: ".").map(String.init)
        let c = current.split(separator: ".").map(String.init)
        let count = max(r.count, c.count)
        for i in 0..<count {
            let rs = i < r.count ? r[i] : "0"
            let cs = i < c.count ? c[i] : "0"
            if let ri = Int(rs), let ci = Int(cs) {
                if ri != ci { return ri > ci ? .orderedDescending : .orderedAscending }
            } else if rs != cs {
                return rs > cs ? .orderedDescending : .orderedAscending
            }
        }
        return .orderedSame
    }
}
