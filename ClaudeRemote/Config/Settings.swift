import Foundation
import Security
import Observation

// Centralized settings management.
// UserDefaults for preferences, Keychain for secrets.
// Writes .env file for the telegram-relay Node.js process.
@MainActor
@Observable
final class Settings {
    // MARK: - Presence Detection Settings

    var idleThreshold: TimeInterval {
        didSet { UserDefaults.standard.set(idleThreshold, forKey: Constants.Defaults.idleThreshold) }
    }

    var screenLockAway: Bool {
        didSet { UserDefaults.standard.set(screenLockAway, forKey: Constants.Defaults.screenLockAway) }
    }

    var displaySleepAway: Bool {
        didSet { UserDefaults.standard.set(displaySleepAway, forKey: Constants.Defaults.displaySleepAway) }
    }

    /// Detection mode: "automatic" or "manual"
    var detectionMode: DetectionMode {
        didSet { UserDefaults.standard.set(detectionMode.rawValue, forKey: Constants.Defaults.detectionMode) }
    }

    var manualAway: Bool {
        didSet { UserDefaults.standard.set(manualAway, forKey: Constants.Defaults.manualAway) }
    }

    // MARK: - Notification Preferences

    var notifyLocalWhenPresent: Bool {
        didSet { UserDefaults.standard.set(notifyLocalWhenPresent, forKey: Constants.Defaults.notifyLocalWhenPresent) }
    }

    var notifySoundWhenPresent: Bool {
        didSet { UserDefaults.standard.set(notifySoundWhenPresent, forKey: Constants.Defaults.notifySoundWhenPresent) }
    }

    var notifyTelegramWhenAway: Bool {
        didSet { UserDefaults.standard.set(notifyTelegramWhenAway, forKey: Constants.Defaults.notifyTelegramWhenAway) }
    }

    var notifyLocalWhenAway: Bool {
        didSet { UserDefaults.standard.set(notifyLocalWhenAway, forKey: Constants.Defaults.notifyLocalWhenAway) }
    }

    // MARK: - tmux

    var tmuxSessionName: String {
        didSet {
            UserDefaults.standard.set(tmuxSessionName, forKey: Constants.Defaults.tmuxSessionName)
            writeEnvFile()
        }
    }

    // MARK: - Launch at Login

    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: Constants.Defaults.launchAtLogin) }
    }

    // MARK: - Initialization

    init() {
        let defaults = UserDefaults.standard

        // Register default values on first launch
        defaults.register(defaults: [
            Constants.Defaults.idleThreshold: Constants.defaultIdleThresholdSeconds,
            Constants.Defaults.screenLockAway: true,
            Constants.Defaults.displaySleepAway: true,
            Constants.Defaults.detectionMode: DetectionMode.automatic.rawValue,
            Constants.Defaults.manualAway: false,
            Constants.Defaults.notifyLocalWhenPresent: true,
            Constants.Defaults.notifySoundWhenPresent: false,
            Constants.Defaults.notifyTelegramWhenAway: true,
            Constants.Defaults.notifyLocalWhenAway: true,
            Constants.Defaults.tmuxSessionName: Constants.defaultTmuxSessionName,
            Constants.Defaults.launchAtLogin: false,
        ])

        self.idleThreshold = defaults.double(forKey: Constants.Defaults.idleThreshold)
        self.screenLockAway = defaults.bool(forKey: Constants.Defaults.screenLockAway)
        self.displaySleepAway = defaults.bool(forKey: Constants.Defaults.displaySleepAway)
        self.detectionMode = DetectionMode(rawValue: defaults.string(forKey: Constants.Defaults.detectionMode) ?? "") ?? .automatic
        self.manualAway = defaults.bool(forKey: Constants.Defaults.manualAway)
        self.notifyLocalWhenPresent = defaults.bool(forKey: Constants.Defaults.notifyLocalWhenPresent)
        self.notifySoundWhenPresent = defaults.bool(forKey: Constants.Defaults.notifySoundWhenPresent)
        self.notifyTelegramWhenAway = defaults.bool(forKey: Constants.Defaults.notifyTelegramWhenAway)
        self.notifyLocalWhenAway = defaults.bool(forKey: Constants.Defaults.notifyLocalWhenAway)
        self.tmuxSessionName = defaults.string(forKey: Constants.Defaults.tmuxSessionName) ?? Constants.defaultTmuxSessionName
        self.launchAtLogin = defaults.bool(forKey: Constants.Defaults.launchAtLogin)

        // Ensure shared secret exists on first run
        ensureSharedSecretExists()
    }

    // MARK: - Keychain Operations

    /// Retrieves the Telegram bot token from Keychain
    var telegramBotToken: String? {
        get { keychainRead(account: Constants.keychainTelegramBotToken) }
        set {
            if let value = newValue {
                keychainWrite(account: Constants.keychainTelegramBotToken, value: value)
            } else {
                keychainDelete(account: Constants.keychainTelegramBotToken)
            }
            writeEnvFile()
        }
    }

    /// Retrieves the Telegram user/chat ID from Keychain
    var telegramUserID: String? {
        get { keychainRead(account: Constants.keychainTelegramUserID) }
        set {
            if let value = newValue {
                keychainWrite(account: Constants.keychainTelegramUserID, value: value)
            } else {
                keychainDelete(account: Constants.keychainTelegramUserID)
            }
            writeEnvFile()
        }
    }

    /// Retrieves the shared HTTP secret from Keychain
    var httpSecret: String? {
        get { keychainRead(account: Constants.keychainHTTPSecret) }
        set {
            if let value = newValue {
                keychainWrite(account: Constants.keychainHTTPSecret, value: value)
                writeSecretFile(secret: value)
            } else {
                keychainDelete(account: Constants.keychainHTTPSecret)
            }
            writeEnvFile()
        }
    }

    /// Whether Telegram is configured (both bot token and user ID are set)
    var isTelegramConfigured: Bool {
        telegramBotToken != nil && telegramUserID != nil
    }

    // MARK: - Secret Management

    /// Generates a cryptographically secure random secret and stores it
    private func ensureSharedSecretExists() {
        if keychainRead(account: Constants.keychainHTTPSecret) != nil {
            // Secret already exists in keychain, ensure secret file is in sync
            if let secret = keychainRead(account: Constants.keychainHTTPSecret) {
                writeSecretFile(secret: secret)
            }
            return
        }

        // Generate a new random secret
        var bytes = [UInt8](repeating: 0, count: Constants.secretLengthBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            print("[Settings] Failed to generate random secret: \(status)")
            return
        }

        let secret = Data(bytes).base64EncodedString()
        keychainWrite(account: Constants.keychainHTTPSecret, value: secret)
        writeSecretFile(secret: secret)
        writeEnvFile()
    }

    /// Writes the shared secret to ~/.claude-remote-secret with restricted permissions
    private func writeSecretFile(secret: String) {
        let path = Constants.secretFilePath
        do {
            // Write the file
            try secret.write(toFile: path, atomically: true, encoding: .utf8)
            // Set permissions to 600 (owner read/write only)
            chmod(path, Constants.secretFilePermissions)
        } catch {
            print("[Settings] Failed to write secret file at \(path): \(error)")
        }
    }

    // MARK: - .env File for telegram-relay

    /// Writes the .env file that the Node.js telegram-relay reads
    func writeEnvFile() {
        var lines: [String] = [
            "# Auto-generated by ClaudeRemote. Do not edit manually.",
        ]

        if let token = telegramBotToken {
            lines.append("TELEGRAM_BOT_TOKEN=\(token)")
        }
        if let userID = telegramUserID {
            lines.append("TELEGRAM_USER_ID=\(userID)")
        }
        lines.append("TMUX_SESSION_NAME=\(tmuxSessionName)")
        if let secret = httpSecret {
            lines.append("HTTP_SECRET=\(secret)")
        }

        let content = lines.joined(separator: "\n") + "\n"
        let path = Constants.envFilePath

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            print("[Settings] Failed to write .env file at \(path): \(error)")
        }
    }

    // MARK: - Keychain Helpers

    private func keychainRead(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Try to update first
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: account,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item does not exist yet, add it
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[Settings] Keychain add failed for \(account): \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            print("[Settings] Keychain update failed for \(account): \(updateStatus)")
        }
    }

    private func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Detection Mode

enum DetectionMode: String, CaseIterable {
    case automatic
    case manual
}

