import AppKit
import UserNotifications
import AgentSmithKit
import SwiftLLMKit
import os

/// Posts task-watch macOS notifications and routes a click on one to that task's Task Detail
/// window. The app-side end of the `.external(TaskWatchDelivery.macOSNotificationTarget)`
/// recipient: each session's runtime hands it the firings of `macOSNotification` watches.
///
/// Authorization is asked for the first time a notification is due and checked on EVERY delivery,
/// because the user can revoke it in System Settings at any time. A delivery macOS won't allow is
/// reported back as a refusal with the reason, which the runtime shows in the transcript — never a
/// silent drop.
@MainActor
@Observable
final class TaskNotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Set when the user clicks a task notification; a session scene consumes it
    /// (`consumeTaskDetailRequest`) and opens the window.
    private(set) var pendingTaskDetailRequest: TaskDetailTarget?

    nonisolated private static let logger = Logger(subsystem: "com.agentsmith", category: "TaskNotifications")

    private enum UserInfoKey {
        nonisolated static let sessionID = "sessionID"
        nonisolated static let taskID = "taskID"
    }

    /// Installs this service as the notification center's delegate. Must run before launch
    /// completes, so a click that launched the app is not lost.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Delivers one firing of a `macOSNotification` watch.
    func deliver(_ text: String, for notification: AgentNotification, sessionID: UUID) async -> PushDeliveryOutcome {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return .refused("macOS notifications are turned off for Agent Smith (System Settings ▸ Notifications ▸ Agent Smith)")
        case .notDetermined:
            // Never wait on the permission prompt here: it returns only when the user answers, and
            // delivery runs on the runtime's single task-event consumer, which would stall every
            // other reaction until then. Ask in the background; this one is refused, and later
            // notifications appear once permission is granted.
            Task { await self.requestAuthorizationIfNeeded() }
            return .refused("Agent Smith doesn't have notification permission yet — macOS is asking now; allow it and later notifications will appear")
        @unknown default:
            return .refused("macOS reported a notification permission this version doesn't know")
        }

        let content = UNMutableNotificationContent()
        if case .string(let title)? = notification.payload.data[TaskWatchDelivery.Key.bannerTitle] {
            content.title = title
        } else {
            content.title = notification.title
        }
        content.body = text
        content.sound = .default
        var userInfo: [String: String] = [UserInfoKey.sessionID: sessionID.uuidString]
        if case .string(let taskID)? = notification.payload.data[TaskWatchDelivery.Key.taskID] {
            userInfo[UserInfoKey.taskID] = taskID
        }
        content.userInfo = userInfo
        // The notification's own id: a re-delivery after a crash replaces the banner instead of
        // stacking a duplicate.
        let request = UNNotificationRequest(identifier: notification.id.raw, content: content, trigger: nil)
        do {
            try await center.add(request)
            return .delivered
        } catch {
            return .retryable("macOS refused to post it: \(error.localizedDescription)")
        }
    }

    /// Asks for notification permission if the user has never been asked. Failure is left for
    /// delivery to report: permission is checked again there, where a refusal becomes visible.
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Self.logger.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns and clears the click waiting to be handled, so exactly one scene acts on it.
    func consumeTaskDetailRequest() -> TaskDetailTarget? {
        defer { pendingTaskDetailRequest = nil }
        return pendingTaskDetailRequest
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shows the banner even while Agent Smith is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let rawSession = userInfo[UserInfoKey.sessionID] as? String, let sessionID = UUID(uuidString: rawSession),
              let rawTask = userInfo[UserInfoKey.taskID] as? String, let taskID = UUID(uuidString: rawTask) else {
            Self.logger.error("Clicked notification carried no task to open")
            return
        }
        await MainActor.run {
            let target = TaskDetailTarget(sessionID: sessionID, taskID: taskID)
            pendingTaskDetailRequest = target
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
