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

        // Telegram API limits messages to 4096 characters.
        // If message exceeds the limit, retry without HTML parse mode to avoid broken tags.
        let parseMode: String?
        let finalText: String
        if text.count > Constants.telegramMaxMessageLength {
            print("[TelegramService] Message too long (\(text.count) chars), sending as plain text")
            finalText = stripHTML(text).prefix(Constants.telegramMaxMessageLength).description
            parseMode = nil
        } else {
            finalText = text
            parseMode = "HTML"
        }

        let body = SendMessageBody(
            chatId: chatID,
            text: finalText,
            parseMode: parseMode
        )

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[TelegramService] No HTTP response")
                return false
            }

            if httpResponse.statusCode != 200 {
                let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                print("[TelegramService] API returned status \(httpResponse.statusCode): \(responseBody)")
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
    /// with appropriate structure based on event category.
    /// Terminal context is only included for permission requests where it's actionable.
    /// Claude's markdown in messages is converted to Telegram-compatible HTML.
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
                parts.append(markdownToTelegramHTML(message))
            }
            // Terminal context is useful for permission requests to see what's being asked
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
                parts.append(markdownToTelegramHTML(message))
            }
            parts.append("")
            parts.append("Reply /select N or type your answer")

        case .stop:
            parts.append("<b>Claude finished</b>")
            parts.append("")
            if let message = payload.message {
                parts.append(markdownToTelegramHTML(message))
            }
            parts.append("")
            parts.append("Send next prompt or /status for full view")

        case .generic:
            parts.append("<b>Claude Code</b>")
            parts.append("")
            if let title = payload.title {
                parts.append(escapeHTML(title))
            }
            if let message = payload.message {
                parts.append(markdownToTelegramHTML(message))
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

    // MARK: - Markdown to Telegram HTML Conversion

    /// Converts Claude's markdown output to Telegram-compatible HTML.
    /// Handles: bold, italic, inline code, code blocks, and cleans up list markers.
    private func markdownToTelegramHTML(_ markdown: String) -> String {
        var text = markdown

        // Convert fenced code blocks (```language\n...\n```) to <pre> before escaping
        let codeBlockPattern = "```[a-zA-Z]*\\n([\\s\\S]*?)```"
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "<pre>$1</pre>")
        }

        // Extract <pre> blocks to protect them from further processing
        var preBlocks: [String] = []
        let prePlaceholderPrefix = "\u{FFFC}PRE_BLOCK_"
        if let preRegex = try? NSRegularExpression(pattern: "<pre>([\\s\\S]*?)</pre>", options: []) {
            let nsText = text as NSString
            let matches = preRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let fullRange = match.range
                let content = nsText.substring(with: match.range(at: 1))
                let index = preBlocks.count
                preBlocks.append(content)
                text = nsText.replacingCharacters(in: fullRange, with: "\(prePlaceholderPrefix)\(index)\u{FFFC}") as String
            }
        }

        // Escape HTML special characters in the remaining text
        text = escapeHTML(text)

        // Convert inline code (`code`) to <code>
        if let inlineCodeRegex = try? NSRegularExpression(pattern: "`([^`]+)`", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = inlineCodeRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "<code>$1</code>")
        }

        // Convert bold (**text** or __text__) to <b>
        if let boldRegex = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*|__(.+?)__", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = boldRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "<b>$1$2</b>")
        }

        // Convert italic (*text* or _text_) - but not inside words with underscores
        if let italicRegex = try? NSRegularExpression(pattern: "(?<![\\w*])\\*([^*]+)\\*(?![\\w*])|(?<![\\w_])_([^_]+)_(?![\\w_])", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            text = italicRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "<i>$1$2</i>")
        }

        // Restore <pre> blocks with their content HTML-escaped
        for (index, content) in preBlocks.enumerated() {
            text = text.replacingOccurrences(of: "\(prePlaceholderPrefix)\(index)\u{FFFC}", with: "<pre>\(escapeHTML(content))</pre>")
        }

        return text
    }

    /// Escapes HTML special characters for Telegram's HTML parse mode
    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Trims excessive whitespace from terminal context and limits line count and total length
    private func trimmedContext(_ context: String) -> String {
        let maxContextLines = 15
        let maxContextChars = 2000
        let lines = context.components(separatedBy: "\n")
        let trimmed = lines.suffix(maxContextLines)
        let joined = trimmed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.count > maxContextChars {
            return String(joined.prefix(maxContextChars)) + "\n..."
        }
        return joined
    }

    /// Strips HTML tags for fallback plain text sending
    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

// MARK: - Telegram API Models

private struct SendMessageBody: Encodable {
    let chatId: String
    let text: String
    let parseMode: String?

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
