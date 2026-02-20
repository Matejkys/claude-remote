import Foundation
import Observation

// Central application state that tracks presence, connection statuses, and CC state.
// All UI and services observe this to make routing decisions.
@MainActor
@Observable
final class AppState {
    // MARK: - Dependencies

    let settings: Settings

    // MARK: - Presence Detection (set by PresenceDetector)

    /// Whether the system idle time exceeds the configured threshold
    var isIdleTimerExpired = false
    /// Whether the screen is currently locked
    var isScreenLocked = false
    /// Whether the display is currently asleep
    var isDisplayAsleep = false

    // MARK: - Computed Presence

    /// Whether the user is considered away from the computer.
    /// In automatic mode: away if any automatic detection signal fires.
    /// In manual mode: away if the user toggled the manual switch.
    var isAway: Bool {
        switch settings.detectionMode {
        case .automatic:
            var away = isIdleTimerExpired
            if settings.screenLockAway {
                away = away || isScreenLocked
            }
            if settings.displaySleepAway {
                away = away || isDisplayAsleep
            }
            return away
        case .manual:
            return settings.manualAway
        }
    }

    // MARK: - Telegram Connection Status

    enum TelegramStatus: Equatable {
        case notConfigured
        case checking
        case connected(botName: String)
        case error(String)
    }

    var telegramStatus: TelegramStatus = .notConfigured

    // MARK: - Claude Code / Relay Status

    enum ServiceStatus: Equatable {
        case stopped
        case running
        case error(String)
    }

    var claudeCodeStatus: ServiceStatus = .stopped
    var relayStatus: ServiceStatus = .stopped

    // MARK: - tmux Sessions

    struct TmuxSession: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let windows: Int
        let created: String
        let projectName: String?
    }

    var tmuxSessions: [TmuxSession] = []

    // MARK: - HTTP Listener Status

    var httpListenerRunning = false

    // MARK: - Initialization

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Menu Bar Icon

    /// SF Symbol name for the menu bar icon based on current presence state
    var menuBarIconName: String {
        isAway ? "circle.dotted.circle.fill" : "circle.dotted.circle.fill"
    }

    /// Tint color name for the menu bar icon
    var menuBarIconColor: String {
        isAway ? "orange" : "green"
    }

    /// Status description shown at the top of the popover
    var statusDescription: String {
        isAway ? "Away" : "At computer"
    }
}
