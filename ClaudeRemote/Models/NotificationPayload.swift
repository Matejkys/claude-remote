import Foundation

// Represents the JSON payload sent by the CC hook script to the HTTP listener.
// The hook script enriches the original CC notification with tmux pane ID and terminal context.
struct NotificationPayload: Codable, Sendable {
    // MARK: - Original CC Hook Fields

    /// Type of the notification: "Notification" for permission/question prompts, "Stop" for task completion
    let type: NotificationType
    /// Notification title (e.g., "Permission Request", "Claude is asking")
    let title: String?
    /// Notification message body with details
    let message: String?

    // MARK: - Enriched Fields (added by notify-hook.sh)

    /// tmux pane ID where CC is running (e.g., "%0", "%1")
    let tmuxPane: String?
    /// Last N lines of terminal output captured from the tmux pane
    let terminalContext: String?

    enum CodingKeys: String, CodingKey {
        case type
        case title
        case message
        case tmuxPane = "tmux_pane"
        case terminalContext = "terminal_context"
    }
}

// MARK: - Notification Type

enum NotificationType: String, Codable, Sendable {
    case notification = "Notification"
    case stop = "Stop"

    // Fallback for any unknown types
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = NotificationType(rawValue: rawValue) ?? .notification
    }
}

// MARK: - Convenience

extension NotificationPayload {
    /// Determines the semantic event category for message formatting
    var eventCategory: EventCategory {
        // Check title and message content to categorize the event
        let combinedText = [title, message].compactMap { $0 }.joined(separator: " ").lowercased()

        if type == .stop {
            return .stop
        } else if combinedText.contains("permission") || combinedText.contains("approve") || combinedText.contains("allow") {
            return .permission
        } else if combinedText.contains("question") || combinedText.contains("asking") || combinedText.contains("input") {
            return .question
        } else {
            return .generic
        }
    }

    enum EventCategory: Sendable {
        case permission
        case question
        case stop
        case generic
    }
}
