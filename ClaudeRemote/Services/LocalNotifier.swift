import Foundation
import UserNotifications

// Delivers native macOS notifications via UNUserNotificationCenter.
// Supports action buttons for permission prompts (Approve/Deny).
// Requests notification permission on first use.
@MainActor
final class LocalNotifier: NSObject {
    private let center = UNUserNotificationCenter.current()
    private var permissionGranted = false

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
        requestPermission()
    }

    // MARK: - Permission

    /// Requests notification permission from the user.
    /// Called on initialization - the system will only prompt once.
    private func requestPermission() {
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                self.permissionGranted = granted
                if !granted {
                    print("[LocalNotifier] Notification permission denied by user")
                }
            } catch {
                print("[LocalNotifier] Failed to request notification permission: \(error)")
            }
        }
    }

    // MARK: - Categories with Actions

    /// Registers notification categories with action buttons.
    /// The permission prompt category has Approve/Deny buttons.
    private func registerCategories() {
        let approveAction = UNNotificationAction(
            identifier: Constants.notificationActionApprove,
            title: "Approve",
            options: [.foreground]
        )

        let denyAction = UNNotificationAction(
            identifier: Constants.notificationActionDeny,
            title: "Deny",
            options: [.destructive]
        )

        let permissionCategory = UNNotificationCategory(
            identifier: Constants.notificationCategoryPermission,
            actions: [approveAction, denyAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([permissionCategory])
    }

    // MARK: - Send Notification

    /// Delivers a local notification based on the CC notification payload.
    /// Permission-type notifications include Approve/Deny action buttons.
    /// Sound is controlled by the user's macOS System Settings.
    func send(payload: NotificationPayload) async {
        let content = UNMutableNotificationContent()

        // Set title based on event category
        switch payload.eventCategory {
        case .permission:
            content.title = "Permission Request"
            content.categoryIdentifier = Constants.notificationCategoryPermission
        case .question:
            content.title = "Claude is asking"
        case .stop:
            content.title = "Claude finished"
        case .generic:
            content.title = payload.title ?? "Claude Code"
        }

        // Build the body from available fields
        var bodyParts: [String] = []
        if let title = payload.title, payload.eventCategory == .generic || payload.eventCategory == .permission {
            bodyParts.append(title)
        }
        if let message = payload.message {
            bodyParts.append(message)
        }
        content.body = bodyParts.joined(separator: "\n")

        // Always use default sound - user controls this in System Settings
        content.sound = .default

        // Use a unique identifier so multiple notifications don't replace each other
        let identifier = "claude-remote-\(UUID().uuidString)"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await center.add(request)
        } catch {
            print("[LocalNotifier] Failed to deliver notification: \(error)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension LocalNotifier: UNUserNotificationCenterDelegate {
    /// Show notifications even when the app is in the foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    /// Handle notification action button presses (Approve/Deny)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        switch response.actionIdentifier {
        case Constants.notificationActionApprove:
            print("[LocalNotifier] User tapped Approve - sending to tmux would require relay")
        case Constants.notificationActionDeny:
            print("[LocalNotifier] User tapped Deny - sending to tmux would require relay")
        default:
            break
        }
    }
}
