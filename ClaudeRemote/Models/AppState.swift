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

    struct TmuxSession: Identifiable, Equatable, Hashable {
        var id: String { name }
        var name: String
        let windows: Int
        let createdAt: Date
        let lastActivity: Date
        var projectName: String?
        var state: TmuxService.PaneState
        var panes: [TmuxService.PaneInfo]

        /// Display name: project name if available, otherwise session name
        var displayName: String {
            projectName ?? name
        }

        /// Formatted creation time
        var createdFormatted: String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: createdAt, relativeTo: Date())
        }
    }

    var tmuxSessions: [TmuxSession] = []

    // MARK: - HTTP Listener Status

    var httpListenerRunning = false

    // MARK: - User Feedback

    /// Transient success message shown in the UI, auto-clears
    var successMessage: String?
    /// Transient error message shown in the UI, auto-clears
    var errorMessage: String?

    /// Shows a success message that auto-clears after a delay
    func showSuccess(_ message: String) {
        successMessage = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if successMessage == message {
                successMessage = nil
            }
        }
    }

    /// Shows an error message that auto-clears after a delay
    func showError(_ message: String) {
        errorMessage = message
        Task {
            try? await Task.sleep(for: .seconds(5))
            if errorMessage == message {
                errorMessage = nil
            }
        }
    }

    // MARK: - Initialization

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Menu Bar Icon

    /// SF Symbol name for the menu bar icon based on current presence state
    var menuBarIconName: String {
        "circle.dotted.circle.fill"
    }

    /// Tint color name for the menu bar icon
    var menuBarIconColor: String {
        isAway ? "orange" : "green"
    }

    /// Status description shown at the top of the popover
    var statusDescription: String {
        isAway ? "Away" : "At computer"
    }

    // MARK: - Session Helpers

    /// Number of sessions waiting for input
    var waitingSessionCount: Int {
        tmuxSessions.filter { $0.state.isWaiting }.count
    }

    /// Total active session count
    var activeSessionCount: Int {
        tmuxSessions.count
    }
}
