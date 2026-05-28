// MeetingNotifier.swift
// ============================================================
// Fires system-level "Transcript ready" notifications when a
// meeting finishes processing in the background. Voice is
// LSUIElement so the user usually has another app focused
// while transcription grinds — toasts in BigMenu aren't
// enough; UNUserNotifications cut through.
//
// Behavior:
//   • requestAuth() once at launch — first time prompts the
//     user, subsequent launches are no-op
//   • notify(title:body:) posts a banner with the meeting
//     title as the heading and a short body line
//   • Notifications carry a meetingId in userInfo so a future
//     click handler can open BigMenu pre-scrolled to that row
// ============================================================

import Foundation
import UserNotifications

/// UN delegate singleton. macOS delivers notification taps to whatever object
/// is set as `UNUserNotificationCenter.current().delegate`. We translate the
/// tap into a NotificationCenter post so AppDelegate (which owns the windows)
/// can react without us reaching across modules.
final class MeetingNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingNotificationDelegate()

    /// Show the banner even while Voice is foreground — without this, taps on
    /// our own notifications get swallowed when the user is in BigMenu.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard let meetingId = info["meetingId"] as? String, !meetingId.isEmpty else {
            print("[VOICE-NOTIF] click received with no meetingId — opening BigMenu only")
            NotificationCenter.default.post(name: .voiceOpenBigMenu, object: nil)
            return
        }
        print("[VOICE-NOTIF] click received for meetingId=\(meetingId)")
        NotificationCenter.default.post(
            name: .voiceOpenMeetingFromNotification,
            object: nil,
            userInfo: ["meetingId": meetingId]
        )
    }
}

extension Notification.Name {
    /// Posted when the user clicks a "meeting saved" system notification.
    /// userInfo carries `meetingId: String` — VoiceApp listens and opens BigMenu
    /// scrolled to that row.
    static let voiceOpenMeetingFromNotification = Notification.Name("voiceOpenMeetingFromNotification")
}

enum MeetingNotifier {
    /// Expose the singleton so VoiceApp can wire it as the UN delegate at launch.
    static let delegate = MeetingNotificationDelegate.shared

    /// Request notification permission. Idempotent — macOS only prompts on
    /// first call per app. Failure is logged but not surfaced; the worst
    /// case is the user just doesn't get notifications.
    static func requestAuthIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        print("[VOICE-NOTIF] auth error: \(error.localizedDescription)")
                    } else {
                        print("[VOICE-NOTIF] auth granted: \(granted)")
                    }
                }
            case .denied:
                print("[VOICE-NOTIF] user denied notifications — silent mode")
            default:
                break
            }
        }
    }

    /// Post a banner notification. No-op if the user denied permission.
    /// `meetingId` flows through userInfo so we can route a tap back into
    /// the right meeting row later.
    static func notify(title: String, body: String, meetingId: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let meetingId {
            content.userInfo = ["meetingId": meetingId]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // immediate
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[VOICE-NOTIF] post failed: \(error.localizedDescription)")
            }
        }
    }
}
