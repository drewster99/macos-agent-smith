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
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return .refused("macOS would not ask for notification permission: \(error.localizedDescription)")
            }
            status = await center.notificationSettings().authorizationStatus
        }
        switch status {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return .refused("macOS notifications are turned off for Agent Smith (System Settings ▸ Notifications ▸ Agent Smith)")
        case .notDetermined:
            return .refused("notification permission was not granted")
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
