import Foundation

// Routes incoming CC notifications to the appropriate delivery channel
// based on the user's current presence state and notification preferences.
@MainActor
final class NotificationRouter {
    private let appState: AppState
    private let settings: Settings
    private let telegramService: TelegramService
    private let localNotifier: LocalNotifier

    init(appState: AppState, settings: Settings, telegramService: TelegramService, localNotifier: LocalNotifier) {
        self.appState = appState
        self.settings = settings
        self.telegramService = telegramService
        self.localNotifier = localNotifier
    }

    /// Routes a notification payload to the correct channel(s) based on presence and preferences.
    func route(payload: NotificationPayload) async {
        let isAway = appState.isAway
        let detectionMode = settings.detectionMode
        let manualAway = settings.manualAway

        print("[NotificationRouter] Routing notification:")
        print("  - isAway: \(isAway)")
        print("  - detectionMode: \(detectionMode)")
        print("  - manualAway: \(manualAway)")
        print("  - eventCategory: \(payload.eventCategory)")
        print("  - title: \(payload.title ?? "nil")")

        if isAway {
            print("[NotificationRouter] User is AWAY - routing to Telegram")
            await routeAway(payload: payload)
        } else {
            print("[NotificationRouter] User is PRESENT - routing to local notification")
            await routePresent(payload: payload)
        }
    }

    // MARK: - Private Routing

    /// Routes notification when user IS at the computer
    /// Always sends macOS notification (user controls sound in System Settings)
    private func routePresent(payload: NotificationPayload) async {
        print("[NotificationRouter] Sending local notification")
        await localNotifier.send(payload: payload)
    }

    /// Routes notification when user is AWAY from the computer
    /// Only sends Telegram notification (if configured), never local
    private func routeAway(payload: NotificationPayload) async {
        if settings.isTelegramConfigured {
            print("[NotificationRouter] Telegram is configured - sending notification")
            await telegramService.send(payload: payload)
        } else {
            print("[NotificationRouter] WARNING: User is away but Telegram is NOT configured!")
            print("[NotificationRouter] Notification will be lost. Configure Telegram in the app.")
        }
    }
}
