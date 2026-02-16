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
        if appState.isAway {
            await routeAway(payload: payload)
        } else {
            await routePresent(payload: payload)
        }
    }

    // MARK: - Private Routing

    /// Routes notification when user IS at the computer
    private func routePresent(payload: NotificationPayload) async {
        if settings.notifyLocalWhenPresent {
            await localNotifier.send(
                payload: payload,
                playSound: settings.notifySoundWhenPresent
            )
        }
    }

    /// Routes notification when user is AWAY from the computer
    private func routeAway(payload: NotificationPayload) async {
        // Send to Telegram if configured and enabled
        if settings.notifyTelegramWhenAway && settings.isTelegramConfigured {
            await telegramService.send(payload: payload)
        }

        // Also send local notification if enabled (useful for when user returns)
        if settings.notifyLocalWhenAway {
            await localNotifier.send(
                payload: payload,
                playSound: false // Never play sound when away - user is not there to hear it
            )
        }
    }
}
