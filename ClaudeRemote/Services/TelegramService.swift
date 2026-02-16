import Foundation

// Sends notifications to Telegram via the Bot API.
// Formats messages differently based on event type (permission, question, stop)
// and includes terminal context for remote debugging.
@MainActor
final class TelegramService {
    private let settings: Settings
    private let session: URLSession

    init(settings: Settings) {
        self.settings = settings
        // Use a dedicated ephemeral session to avoid caching API responses
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Send Notification

    /// Sends a formatted notification to the configured Telegram chat
    func send(payload: NotificationPayload) async {
        guard let token = settings.telegramBotToken,
              let chatID = settings.telegramUserID
        else {
            print("[TelegramService] ERROR: Cannot send - Telegram not configured")
            print("[TelegramService] Token exists: \(settings.telegramBotToken != nil)")
            print("[TelegramService] Chat ID exists: \(settings.telegramUserID != nil)")
            return
        }

        print("[TelegramService] Sending notification to Telegram")
        print("[TelegramService] Event: \(payload.eventCategory), Title: \(payload.title ?? "nil")")

        let text = formatMessage(payload: payload)
        let success = await sendMessage(token: token, chatID: chatID, text: text)

        if success {
            print("[TelegramService] ✓ Notification sent successfully")
        } else {
            print("[TelegramService] ✗ FAILED to send notification")
        }
    }

    // MARK: - Test Connection

    /// Sends a test message to verify bot token and chat ID are correct.
    /// Returns the bot username on success, or throws on failure.
    func testConnection() async throws -> String {
        guard let token = settings.telegramBotToken,
              let chatID = settings.telegramUserID
        else {
            throw TelegramError.notConfigured
        }

        // First, verify the bot token by calling getMe
        let botName = try await getBotInfo(token: token)

        // Then verify the chat ID by sending a test message
        let testText = "Claude Remote connected successfully. Notifications will be sent here."
        let success = await sendMessage(token: token, chatID: chatID, text: testText)
        if !success {
            throw TelegramError.sendFailed
        }

        return botName
    }

    // MARK: - Bot Info

    /// Calls the getMe API to retrieve bot information
    private func getBotInfo(token: String) async throws -> String {
        let url = URL(string: "\(Constants.telegramAPIBaseURL)/bot\(token)/getMe")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw TelegramError.invalidToken
        }

        let result = try JSONDecoder().decode(TelegramResponse<BotInfo>.self, from: data)
        guard result.ok, let botInfo = result.result else {
            throw TelegramError.invalidToken
        }

        return "@\(botInfo.username)"
    }

    // MARK: - Send Message

    @discardableResult
    private func sendMessage(token: String, chatID: String, text: String) async -> Bool {
        let url = URL(string: "\(Constants.telegramAPIBaseURL)/bot\(token)/sendMessage")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = SendMessageBody(
            chatId: chatID,
            text: text,
            parseMode: "HTML"
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[TelegramService] No HTTP response")
                return false
            }

            if httpResponse.statusCode != 200 {
                print("[TelegramService] API returned status \(httpResponse.statusCode)")
                return false
            }

            return true
        } catch {
            print("[TelegramService] Send failed: \(error)")
            return false
        }
    }

    // MARK: - Message Formatting

    /// Formats a NotificationPayload into a human-readable Telegram message
    /// with appropriate emoji and structure based on event category.
    private func formatMessage(payload: NotificationPayload) -> String {
        var parts: [String] = []

        switch payload.eventCategory {
        case .permission:
            parts.append("<b>Permission Request</b>")
            parts.append("")
            if let title = payload.title {
                parts.append(escapeHTML(title))
            }
            if let message = payload.message {
                parts.append(escapeHTML(message))
            }
            if let context = payload.terminalContext, !context.isEmpty {
                parts.append("")
                parts.append("<pre>")
                parts.append(escapeHTML(trimmedContext(context)))
                parts.append("</pre>")
            }
            parts.append("")
            parts.append("/y to approve | /n to deny")

        case .question:
            parts.append("<b>Claude is asking:</b>")
            parts.append("")
            if let title = payload.title {
                parts.append(escapeHTML(title))
            }
            if let message = payload.message {
                parts.append(escapeHTML(message))
            }
            if let context = payload.terminalContext, !context.isEmpty {
                parts.append("")
                parts.append("<pre>")
                parts.append(escapeHTML(trimmedContext(context)))
                parts.append("</pre>")
            }
            parts.append("")
            parts.append("Reply /select N or type your answer")

        case .stop:
            parts.append("<b>Claude finished</b>")
            parts.append("")
            if let title = payload.title {
                parts.append(escapeHTML(title))
            }
            if let message = payload.message {
                parts.append(escapeHTML(message))
            }
            if let context = payload.terminalContext, !context.isEmpty {
                parts.append("")
                parts.append("<pre>")
                parts.append(escapeHTML(trimmedContext(context)))
                parts.append("</pre>")
            }
            parts.append("")
            parts.append("Send next prompt or /status for full view")

        case .generic:
            parts.append("<b>Claude Code Notification</b>")
            parts.append("")
            if let title = payload.title {
                parts.append(escapeHTML(title))
            }
            if let message = payload.message {
                parts.append(escapeHTML(message))
            }
            if let context = payload.terminalContext, !context.isEmpty {
                parts.append("")
                parts.append("<pre>")
                parts.append(escapeHTML(trimmedContext(context)))
                parts.append("</pre>")
            }
        }

        // Include project/session info if available
        var contextParts: [String] = []

        if let project = payload.projectName, !project.isEmpty {
            contextParts.append("Project: \(escapeHTML(project))")
        }

        if let session = payload.tmuxSession, !session.isEmpty {
            contextParts.append("Session: \(escapeHTML(session))")
        }

        if let pane = payload.tmuxPane, !pane.isEmpty {
            contextParts.append("Pane: \(escapeHTML(pane))")
        }

        if !contextParts.isEmpty {
            parts.append("")
            parts.append("<i>\(contextParts.joined(separator: " | "))</i>")
        }

        return parts.joined(separator: "\n")
    }

    /// Escapes HTML special characters for Telegram's HTML parse mode
    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Trims excessive whitespace from terminal context and limits line count
    private func trimmedContext(_ context: String) -> String {
        let maxContextLines = 20
        let lines = context.components(separatedBy: "\n")
        let trimmed = lines.suffix(maxContextLines)
        return trimmed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Telegram API Models

private struct SendMessageBody: Encodable {
    let chatId: String
    let text: String
    let parseMode: String

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case text
        case parseMode = "parse_mode"
    }
}

private struct TelegramResponse<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
}

private struct BotInfo: Decodable {
    let id: Int
    let username: String
}

// MARK: - Errors

enum TelegramError: LocalizedError {
    case notConfigured
    case invalidToken
    case sendFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Telegram bot token and user ID are not configured"
        case .invalidToken:
            return "Invalid bot token - check the token from @BotFather"
        case .sendFailed:
            return "Failed to send message - check the chat ID"
        }
    }
}
