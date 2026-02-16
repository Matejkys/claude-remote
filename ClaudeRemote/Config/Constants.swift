import Foundation

// All application constants in a single location.
// Never hardcode values elsewhere - reference these constants instead.
enum Constants {
    // MARK: - HTTP Listener
    /// Port for the local HTTP listener that receives CC hook notifications
    static let httpListenerPort: UInt16 = 7677
    /// Host binding for the HTTP listener (localhost only for security)
    static let httpListenerHost = "127.0.0.1"

    // MARK: - Presence Detection
    /// Default idle threshold in seconds before user is considered away (5 minutes)
    static let defaultIdleThresholdSeconds: TimeInterval = 300
    /// Interval in seconds between idle time polling checks
    static let idlePollingIntervalSeconds: TimeInterval = 30

    // MARK: - Idle Threshold Options
    /// Available idle threshold options for the UI picker, in seconds
    static let idleThresholdOptions: [TimeInterval] = [
        60,     // 1 minute
        120,    // 2 minutes
        180,    // 3 minutes
        300,    // 5 minutes
        600,    // 10 minutes
        900,    // 15 minutes
        1800,   // 30 minutes
    ]

    // MARK: - tmux
    /// Default tmux session name where Claude Code runs
    static let defaultTmuxSessionName = "claude"
    /// Prefix for tmux session names created by cy() function
    static let tmuxSessionPrefix = "claude-"
    /// Interval in seconds between tmux session list refreshes
    static let tmuxPollingIntervalSeconds: TimeInterval = 5
    /// Full path to tmux binary (Homebrew on Apple Silicon)
    static let tmuxPath = "/opt/homebrew/bin/tmux"

    // MARK: - Telegram
    /// Telegram Bot API base URL
    static let telegramAPIBaseURL = "https://api.telegram.org"

    // MARK: - Keychain
    /// Keychain service identifier for this application
    static let keychainService = "com.matejkys.ClaudeRemote"
    /// Keychain account key for the Telegram bot token
    static let keychainTelegramBotToken = "telegram-bot-token"
    /// Keychain account key for the Telegram user ID (chat ID)
    static let keychainTelegramUserID = "telegram-user-id"
    /// Keychain account key for the shared HTTP secret
    static let keychainHTTPSecret = "http-secret"

    // MARK: - Files
    /// Path to the shared secret file used by the hook script
    static let secretFilePath = "\(NSHomeDirectory())/.claude-remote-secret"
    /// Path to the .env file written for the telegram-relay
    static let envFilePath: String = {
        // Navigate from the binary's bundle to the project root
        // In development, use a known path relative to the project
        let projectRoot = NSHomeDirectory() + "/Development/tools/claude-remote"
        return projectRoot + "/.env"
    }()

    // MARK: - UserDefaults Keys
    enum Defaults {
        static let idleThreshold = "idleThreshold"
        static let screenLockAway = "screenLockAway"
        static let displaySleepAway = "displaySleepAway"
        static let detectionMode = "detectionMode"
        static let manualAway = "manualAway"
        static let notifyLocalWhenPresent = "notifyLocalWhenPresent"
        static let notifySoundWhenPresent = "notifySoundWhenPresent"
        static let notifyTelegramWhenAway = "notifyTelegramWhenAway"
        static let notifyLocalWhenAway = "notifyLocalWhenAway"
        static let tmuxSessionName = "tmuxSessionName"
        static let launchAtLogin = "launchAtLogin"
    }

    // MARK: - Bundle
    static let bundleIdentifier = "com.matejkys.ClaudeRemote"

    // MARK: - Notification
    /// Notification category identifier for permission prompts (with action buttons)
    static let notificationCategoryPermission = "PERMISSION_PROMPT"
    /// Action identifiers for permission prompt notification buttons
    static let notificationActionApprove = "APPROVE_ACTION"
    static let notificationActionDeny = "DENY_ACTION"

    // MARK: - Secret Generation
    /// Length of the auto-generated shared secret in bytes (32 bytes = 256 bits)
    static let secretLengthBytes = 32
    /// File permission mode for the secret file (owner read/write only)
    static let secretFilePermissions: mode_t = 0o600
}
