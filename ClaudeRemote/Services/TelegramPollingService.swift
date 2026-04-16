import Foundation

// Receives commands from Telegram via getUpdates long-polling and routes them
// to the appropriate tmux panes. Replaces the standalone Node.js telegram-relay.
// Handles: /y, /n, /select, /pane, /prompt, /status, /sessions, and free text.
final class TelegramPollingService: @unchecked Sendable {
    private let settings: Settings
    private let tmuxService: TmuxService
    private let session: URLSession
    private var pollingTask: Task<Void, Never>?
    private var updateOffset: Int = 0
    private let statusUpdateHandler: @Sendable (Bool) -> Void

    // Stores pending text for inline keyboard pane selection (prompt/free text)
    private var pendingText: String?

    // Number of terminal lines to capture for status extraction
    private static let statusCaptureLines = 80

    // Maximum lines of content to show in status message
    private static let statusDisplayLines = 20

    // Long-polling timeout in seconds (Telegram recommends 30)
    private static let pollingTimeoutSeconds = 30

    init(
        settings: Settings,
        tmuxService: TmuxService,
        onStatusChange: @escaping @Sendable (Bool) -> Void
    ) {
        self.settings = settings
        self.tmuxService = tmuxService
        self.statusUpdateHandler = onStatusChange

        let config = URLSessionConfiguration.ephemeral
        // Allow enough time for long-polling + network overhead
        config.timeoutIntervalForRequest = TimeInterval(Self.pollingTimeoutSeconds + 10)
        self.session = URLSession(configuration: config)
    }

    // MARK: - Lifecycle

    func start() {
        guard pollingTask == nil else { return }
        print("[TelegramPolling] Starting polling service")

        pollingTask = Task { [weak self] in
            guard let self else { return }
            self.statusUpdateHandler(true)
            await self.pollingLoop()
            self.statusUpdateHandler(false)
        }
    }

    func stop() {
        print("[TelegramPolling] Stopping polling service")
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Polling Loop

    private func pollingLoop() async {
        while !Task.isCancelled {
            let token: String
            let authorizedUserId: Int

            // Read settings on main actor
            let settingsSnapshot = await MainActor.run {
                (self.settings.telegramBotToken, self.settings.telegramUserID)
            }

            guard let t = settingsSnapshot.0, let uid = settingsSnapshot.1, let parsedUid = Int(uid) else {
                print("[TelegramPolling] Telegram not configured, waiting 10s before retry")
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            token = t
            authorizedUserId = parsedUid

            do {
                let updates = try await fetchUpdates(token: token)
                for update in updates {
                    // Track offset for acknowledgement
                    if update.updateId >= updateOffset {
                        updateOffset = update.updateId + 1
                    }

                    // Security: only process messages from the authorized user
                    guard let message = update.message,
                          let from = message.from,
                          from.id == authorizedUserId
                    else {
                        if let callback = update.callbackQuery,
                           callback.from.id == authorizedUserId {
                            await handleCallbackQuery(token: token, chatId: String(authorizedUserId), callback: callback)
                        }
                        continue
                    }

                    guard let text = message.text else { continue }
                    let chatId = String(message.chat.id)
                    await handleMessage(token: token, chatId: chatId, text: text)
                }
            } catch {
                if Task.isCancelled { break }
                print("[TelegramPolling] Fetch error: \(error.localizedDescription)")
                // Back off on error to avoid hammering the API
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Telegram API

    private func fetchUpdates(token: String) async throws -> [TelegramUpdate] {
        var urlComponents = URLComponents(string: "\(Constants.telegramAPIBaseURL)/bot\(token)/getUpdates")!
        urlComponents.queryItems = [
            URLQueryItem(name: "offset", value: String(updateOffset)),
            URLQueryItem(name: "timeout", value: String(Self.pollingTimeoutSeconds)),
            URLQueryItem(name: "allowed_updates", value: "[\"message\",\"callback_query\"]"),
        ]

        let (data, response) = try await session.data(from: urlComponents.url!)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PollingError.apiError(statusCode: status)
        }

        let decoded = try JSONDecoder().decode(TelegramGetUpdatesResponse.self, from: data)
        guard decoded.ok else {
            throw PollingError.apiError(statusCode: -1)
        }

        return decoded.result
    }

    @discardableResult
    private func reply(token: String, chatId: String, text: String, parseMode: String? = nil) async -> Bool {
        let url = URL(string: "\(Constants.telegramAPIBaseURL)/bot\(token)/sendMessage")!

        struct Body: Encodable {
            let chat_id: String
            let text: String
            let parse_mode: String?
        }

        // If message exceeds limit, strip HTML and truncate
        let finalText: String
        let finalParseMode: String?
        if text.count > Constants.telegramMaxMessageLength {
            finalText = String(stripHTML(text).prefix(Constants.telegramMaxMessageLength))
            finalParseMode = nil
        } else {
            finalText = text
            finalParseMode = parseMode
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(Body(chat_id: chatId, text: finalText, parse_mode: finalParseMode))
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if status == 200 { return true }

            // If HTML parse failed, retry as plain text
            if finalParseMode != nil {
                print("[TelegramPolling] HTML send failed (status \(status)), retrying as plain text")
                let plainText = String(stripHTML(text).prefix(Constants.telegramMaxMessageLength))
                var retryRequest = URLRequest(url: url)
                retryRequest.httpMethod = "POST"
                retryRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                retryRequest.httpBody = try JSONEncoder().encode(Body(chat_id: chatId, text: plainText, parse_mode: nil))
                let (_, retryResponse) = try await session.data(for: retryRequest)
                return (retryResponse as? HTTPURLResponse)?.statusCode == 200
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            print("[TelegramPolling] Reply failed with status \(status): \(body)")
            return false
        } catch {
            print("[TelegramPolling] Reply failed: \(error.localizedDescription)")
            return false
        }
    }

    private func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Sends a message with inline keyboard buttons.
    /// Each button is (label, callbackData).
    @discardableResult
    private func replyWithInlineKeyboard(
        token: String,
        chatId: String,
        text: String,
        buttons: [(label: String, data: String)],
        parseMode: String? = nil
    ) async -> Bool {
        let url = URL(string: "\(Constants.telegramAPIBaseURL)/bot\(token)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build inline keyboard: one button per row
        let keyboard = buttons.map { button in
            [InlineKeyboardButton(text: button.label, callback_data: button.data)]
        }
        let markup = InlineKeyboardMarkup(inline_keyboard: keyboard)

        struct Body: Encodable {
            let chat_id: String
            let text: String
            let parse_mode: String?
            let reply_markup: InlineKeyboardMarkup
        }

        do {
            request.httpBody = try JSONEncoder().encode(
                Body(chat_id: chatId, text: text, parse_mode: parseMode, reply_markup: markup)
            )
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            print("[TelegramPolling] replyWithInlineKeyboard failed: \(error.localizedDescription)")
            return false
        }
    }

    private func answerCallbackQuery(token: String, callbackQueryId: String, text: String) async {
        let url = URL(string: "\(Constants.telegramAPIBaseURL)/bot\(token)/answerCallbackQuery")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            let callback_query_id: String
            let text: String
        }

        do {
            request.httpBody = try JSONEncoder().encode(Body(callback_query_id: callbackQueryId, text: text))
            let _ = try await session.data(for: request)
        } catch {
            print("[TelegramPolling] answerCallbackQuery failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Message Handling

    private func handleMessage(token: String, chatId: String, text: String) async {
        // Parse command or handle as free text
        if text.hasPrefix("/") {
            await handleCommand(token: token, chatId: chatId, text: text)
        } else {
            await handleFreeText(token: token, chatId: chatId, text: text)
        }
    }

    private func handleCommand(token: String, chatId: String, text: String) async {
        let parts = text.split(separator: " ", maxSplits: 1)
        let command = String(parts[0]).lowercased()
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil

        switch command {
        case "/y", "/yes":
            await commandApprove(token: token, chatId: chatId)

        case "/n", "/no":
            await commandDeny(token: token, chatId: chatId)

        case "/select":
            await commandSelect(token: token, chatId: chatId, argument: argument)

        case "/pane":
            await commandPane(token: token, chatId: chatId, argument: argument)

        case "/prompt":
            await commandPrompt(token: token, chatId: chatId, argument: argument)

        case "/status":
            await commandStatus(token: token, chatId: chatId)

        case "/sessions":
            await commandSessions(token: token, chatId: chatId)

        case "/help", "/start":
            await commandHelp(token: token, chatId: chatId)

        default:
            await reply(
                token: token, chatId: chatId,
                text: "Unknown command. Type /help for available commands."
            )
        }
    }

    // MARK: - Command Implementations

    private static let helpText = """
        <b>Claude Remote</b> — control Claude Code sessions from Telegram.

        <b>Responding to prompts</b>
        /y or /yes — approve a permission request
        /n or /no — deny a permission request
        /select &lt;N&gt; — pick a numbered option (e.g. <code>/select 2</code>)
        Or just type free text — it goes to the waiting pane automatically.

        <b>Sending new prompts</b>
        /prompt &lt;text&gt; — send a prompt to an idle session
        Or just type text when no pane is waiting — it's sent as a new prompt.

        <b>Multi-session</b>
        /pane &lt;id&gt; &lt;text&gt; — send to a specific pane (e.g. <code>/pane %3 y</code>)

        <b>Monitoring</b>
        /status — show last 50 lines of terminal output
        /sessions — list all active tmux sessions

        <b>Other</b>
        /help — show this message
        """

    private func commandHelp(token: String, chatId: String) async {
        await reply(token: token, chatId: chatId, text: Self.helpText, parseMode: "HTML")
    }

    private func commandApprove(token: String, chatId: String) async {
        let result = await sendToWaitingPane("y")
        switch result {
        case .sent(let paneId, let session):
            await reply(token: token, chatId: chatId, text: "Approved (\(session) [\(paneId)])")
        case .noneWaiting:
            await reply(token: token, chatId: chatId, text: "No pane is waiting for input.")
        case .multiple(let panes):
            await replyMultiplePanes(token: token, chatId: chatId, panes: panes, action: "approve")
        case .error(let msg):
            await reply(token: token, chatId: chatId, text: "Failed: \(msg)")
        }
    }

    private func commandDeny(token: String, chatId: String) async {
        let result = await sendToWaitingPane("n")
        switch result {
        case .sent(let paneId, let session):
            await reply(token: token, chatId: chatId, text: "Denied (\(session) [\(paneId)])")
        case .noneWaiting:
            await reply(token: token, chatId: chatId, text: "No pane is waiting for input.")
        case .multiple(let panes):
            await replyMultiplePanes(token: token, chatId: chatId, panes: panes, action: "deny")
        case .error(let msg):
            await reply(token: token, chatId: chatId, text: "Failed: \(msg)")
        }
    }

    private func commandSelect(token: String, chatId: String, argument: String?) async {
        guard let selection = argument, let _ = Int(selection) else {
            await reply(token: token, chatId: chatId, text: "Usage: /select <number>\nExample: /select 1")
            return
        }

        let result = await sendToWaitingPane(selection)
        switch result {
        case .sent(let paneId, let session):
            await reply(token: token, chatId: chatId, text: "Selection '\(selection)' sent (\(session) [\(paneId)])")
        case .noneWaiting:
            await reply(token: token, chatId: chatId, text: "No pane is waiting for input.")
        case .multiple(let panes):
            await replyMultiplePanes(token: token, chatId: chatId, panes: panes, action: "select")
        case .error(let msg):
            await reply(token: token, chatId: chatId, text: "Failed: \(msg)")
        }
    }

    private func commandPane(token: String, chatId: String, argument: String?) async {
        guard let args = argument else {
            await reply(token: token, chatId: chatId, text: "Usage: /pane <id> <text>\nExample: /pane %0 y")
            return
        }

        guard let spaceIndex = args.firstIndex(of: " ") else {
            await reply(token: token, chatId: chatId, text: "Usage: /pane <id> <text>\nExample: /pane %0 y")
            return
        }

        let paneId = String(args[args.startIndex..<spaceIndex])
        let text = String(args[args.index(after: spaceIndex)...])

        let sendResult = await tmuxService.sendKeys(paneId: paneId, text: text)

        switch sendResult {
        case .success:
            await reply(token: token, chatId: chatId, text: "Sent to pane \(paneId)")
        case .failure(let error):
            await reply(token: token, chatId: chatId, text: "Failed to send to pane \(paneId): \(error.message)")
        }
    }

    private func commandPrompt(token: String, chatId: String, argument: String?) async {
        guard let text = argument, !text.isEmpty else {
            await reply(token: token, chatId: chatId, text: "Usage: /prompt <text>\nExample: /prompt Explain this code")
            return
        }

        await sendAsPrompt(token: token, chatId: chatId, text: text)
    }

    private func commandStatus(token: String, chatId: String) async {
        let panes = await listAllClaudePanes()

        if panes.isEmpty {
            await reply(token: token, chatId: chatId, text: "No claude-* tmux sessions found.")
            return
        }

        // Single pane - show directly
        if panes.count == 1 {
            await showPaneStatus(token: token, chatId: chatId, pane: panes[0])
            return
        }

        // Multiple panes - show picker
        var buttons: [(label: String, data: String)] = panes.map { pane in
            let label = pane.projectName ?? pane.sessionName
            return (label: "\(label) [\(pane.paneId)]", data: "status_pane:\(pane.paneId)")
        }
        buttons.append((label: "All", data: "status_pane:__all__"))

        await replyWithInlineKeyboard(
            token: token,
            chatId: chatId,
            text: "Select session to view status:",
            buttons: buttons
        )
    }

    private func showPaneStatus(token: String, chatId: String, pane: PaneTarget) async {
        let rawCapture = await tmuxService.capturePane(paneId: pane.paneId, lines: Self.statusCaptureLines)
        let state = await tmuxService.detectPaneState(paneId: pane.paneId)
        let label = pane.projectName ?? pane.sessionName

        var parts: [String] = []

        // Header with state
        let stateEmoji: String
        let stateLabel: String
        switch state {
        case .active:
            stateEmoji = "🔄"
            stateLabel = "Running"
        case .waitingForInput(let pattern):
            stateEmoji = "⏳"
            stateLabel = "Waiting (\(pattern))"
        case .idle:
            stateEmoji = "💤"
            stateLabel = "Idle"
        case .unknown:
            stateEmoji = "❓"
            stateLabel = "Unknown"
        }

        parts.append("<b>\(stateEmoji) \(escapeHTML(label))</b>")
        parts.append("<i>\(escapeHTML(stateLabel)) | \(escapeHTML(pane.sessionName)) [\(escapeHTML(pane.paneId))]</i>")

        // Parse terminal into sections and format
        let sections = parseTerminalOutput(rawCapture)
        let formatted = formatSections(sections)

        if formatted.isEmpty {
            parts.append("")
            parts.append("(no output)")
        } else {
            parts.append("")
            parts.append(formatted)
        }

        // Action hint based on state
        switch state {
        case .waitingForInput:
            parts.append("")
            parts.append("/y to approve | /n to deny | or type your answer")
        case .idle:
            parts.append("")
            parts.append("Send next prompt or type a message")
        default:
            break
        }

        await reply(token: token, chatId: chatId, text: parts.joined(separator: "\n"), parseMode: "HTML")
    }

    // MARK: - Terminal Output Parser

    /// Represents a parsed section of Claude Code terminal output.
    private enum TerminalSection {
        case claudeText(String)
        case toolCall(name: String, args: String)
        case toolOutput([String])
        case userPrompt(String)
    }

    /// Parses raw terminal capture into structured sections.
    private func parseTerminalOutput(_ raw: String) -> [TerminalSection] {
        // Strip ANSI codes (capture-pane without -e already strips them,
        // but just in case, clean up any remnants)
        let stripped = raw.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]|\u{1B}\\([A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}",
            with: "",
            options: .regularExpression
        )

        let lines = stripped.components(separatedBy: "\n")
        var sections: [TerminalSection] = []
        var currentText: [String] = []
        var currentToolOutput: [String] = []

        // Tool call pattern: ⏺ ToolName(args...) or ⏺ Update(file)
        let toolCallNames = ["Bash", "Read", "Write", "Edit", "Update", "Glob", "Grep",
                             "Agent", "Task", "TaskCreate", "TaskUpdate", "TodoWrite",
                             "WebFetch", "WebSearch", "Skill"]

        func flushText() {
            let joined = currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                sections.append(.claudeText(joined))
            }
            currentText = []
        }

        func flushToolOutput() {
            if !currentToolOutput.isEmpty {
                sections.append(.toolOutput(currentToolOutput))
                currentToolOutput = []
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)

            // Skip noise
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("────") { continue }
            if trimmed.hasPrefix("⏵") { continue }
            if trimmed.hasPrefix("✻") || trimmed.hasPrefix("✢") { continue }

            // User prompt: ❯ text
            if trimmed.hasPrefix("❯") {
                flushText()
                flushToolOutput()
                let promptText = String(trimmed.dropFirst()).trimmingCharacters(in: CharacterSet.whitespaces)
                if !promptText.isEmpty {
                    sections.append(.userPrompt(promptText))
                }
                continue
            }

            // Tool call or Claude text: ⏺ ...
            if trimmed.hasPrefix("⏺") {
                let afterMarker = String(trimmed.dropFirst()).trimmingCharacters(in: CharacterSet.whitespaces)

                var isToolCall = false
                for toolName in toolCallNames {
                    if afterMarker.hasPrefix("\(toolName)(") {
                        flushText()
                        flushToolOutput()
                        let argsStart = afterMarker.index(afterMarker.startIndex, offsetBy: toolName.count + 1)
                        var args = String(afterMarker[argsStart...])
                        if args.hasSuffix(")") { args = String(args.dropLast()) }
                        if args.count > 80 { args = String(args.prefix(77)) + "..." }
                        sections.append(.toolCall(name: toolName, args: args))
                        isToolCall = true
                        break
                    }
                }

                if !isToolCall {
                    flushToolOutput()
                    currentText.append(afterMarker)
                }
                continue
            }

            // Tool output: ⎿ ...
            if trimmed.hasPrefix("⎿") {
                flushText()
                let output = String(trimmed.dropFirst()).trimmingCharacters(in: CharacterSet.whitespaces)
                if !output.isEmpty
                    && !output.hasPrefix("Allowed by")
                    && !output.hasPrefix("(timeout") {
                    currentToolOutput.append(output)
                }
                continue
            }

            // Indented continuation (tool output context)
            if line.hasPrefix("  ") && !currentToolOutput.isEmpty {
                if !trimmed.hasPrefix("Allowed by") && !trimmed.hasPrefix("(timeout") {
                    currentToolOutput.append(trimmed)
                }
                continue
            }

            // Indented continuation (Claude text context) — keep HTML
            if line.hasPrefix("  ") && !currentText.isEmpty {
                currentText.append(trimmed)
                continue
            }

            // Collapsed line hints
            if trimmed.hasPrefix("… +") || trimmed.hasPrefix("... +")
                || trimmed.contains("lines (ctrl+o to expand)") {
                continue
            }

            // Fallback
            if !currentToolOutput.isEmpty {
                currentToolOutput.append(trimmed)
            } else {
                currentText.append(trimmed)
            }
        }

        flushText()
        flushToolOutput()

        return sections
    }

    /// Formats parsed sections into Telegram HTML.
    /// Priority: last Claude text message (primary), recent tool calls (compact summary).
    private func formatSections(_ allSections: [TerminalSection]) -> String {
        var parts: [String] = []

        // 1. Find and show the last Claude text — this is the main content
        if let lastText = allSections.last(where: { if case .claudeText = $0 { return true }; return false }),
           case .claudeText(let text) = lastText {
            parts.append(formatClaudeText(text))
        }

        // 2. Collect tool calls that happened AFTER the last Claude text
        //    (these show what Claude is currently doing)
        var afterLastText = false
        var recentTools: [(name: String, args: String)] = []
        for section in allSections {
            if case .claudeText = section {
                afterLastText = true
                recentTools = []  // Reset — only keep tools after the LAST text
                continue
            }
            if afterLastText, case .toolCall(let name, let args) = section {
                recentTools.append((name, args))
            }
        }

        // If there are tool calls after the last text, show them as compact summary
        if !recentTools.isEmpty {
            if !parts.isEmpty { parts.append("") }
            parts.append("<i>Recent actions:</i>")
            // Show last 3 tool calls max
            for tool in recentTools.suffix(3) {
                parts.append("  \(escapeHTML(tool.name)): <code>\(escapeHTML(truncate(tool.args, to: 50)))</code>")
            }
            if recentTools.count > 3 {
                parts.append("  <i>... +\(recentTools.count - 3) more</i>")
            }
        }

        // 3. If no Claude text found at all, show last few tool calls as fallback
        if parts.isEmpty {
            let tools = allSections.compactMap { section -> (String, String)? in
                if case .toolCall(let name, let args) = section { return (name, args) }
                return nil
            }
            if tools.isEmpty { return "" }
            for tool in tools.suffix(3) {
                parts.append("<b>\(escapeHTML(tool.0))</b>: <code>\(escapeHTML(truncate(tool.1, to: 50)))</code>")
            }
        }

        return parts.joined(separator: "\n")
    }

    /// Formats Claude text with structural HTML for Telegram.
    /// Bolds the first line as summary, indents dash-lists.
    private func formatClaudeText(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var resultLines: [String] = []
        var isFirstContentLine = true

        for line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if trimmed.isEmpty {
                resultLines.append("")
                continue
            }

            var formatted = escapeHTML(trimmed)

            // Dash list items: "- Text" → indented
            if formatted.hasPrefix("- ") {
                formatted = "  \(formatted)"
            }

            // First non-empty line → bold as summary
            if isFirstContentLine {
                formatted = "<b>\(formatted)</b>"
                isFirstContentLine = false
            }

            resultLines.append(formatted)
        }

        return resultLines.joined(separator: "\n")
    }

    private func truncate(_ text: String, to maxLength: Int) -> String {
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }


    private func commandSessions(token: String, chatId: String) async {
        let sessionList = await tmuxService.listSessions()

        if sessionList.isEmpty {
            await reply(token: token, chatId: chatId, text: "No active tmux sessions.")
            return
        }

        var lines: [String] = ["<b>Active tmux sessions:</b>"]
        for s in sessionList {
            lines.append("  \(escapeHTML(s.name)) (\(s.windows) windows)")
        }
        await reply(token: token, chatId: chatId, text: lines.joined(separator: "\n"), parseMode: "HTML")
    }

    // MARK: - Free Text Handler

    private func handleFreeText(token: String, chatId: String, text: String) async {
        // Try sending to a pane waiting for input first
        let result = await sendToWaitingPane(text)
        switch result {
        case .sent(let paneId, let session):
            await reply(token: token, chatId: chatId, text: "Response sent to \(session) [\(paneId)]")
        case .multiple(let panes):
            await replyMultiplePanes(token: token, chatId: chatId, panes: panes, action: "respond")
        case .noneWaiting:
            // No waiting pane - send as new prompt to any available pane
            await sendAsPrompt(token: token, chatId: chatId, text: text)
        case .error(let msg):
            await reply(token: token, chatId: chatId, text: "Failed: \(msg)")
        }
    }

    // MARK: - Callback Query Handler

    private func handleCallbackQuery(token: String, chatId: String, callback: TelegramCallbackQuery) async {
        guard let data = callback.data else { return }

        if data.hasPrefix("status_pane:") {
            let paneId = String(data.dropFirst("status_pane:".count))
            await answerCallbackQuery(token: token, callbackQueryId: callback.id, text: "Loading...")

            if paneId == "__all__" {
                // Show all panes
                let panes = await listAllClaudePanes()
                for pane in panes {
                    await showPaneStatus(token: token, chatId: chatId, pane: pane)
                }
            } else {
                // Find pane info for proper header
                let panes = await listAllClaudePanes()
                if let pane = panes.first(where: { $0.paneId == paneId }) {
                    await showPaneStatus(token: token, chatId: chatId, pane: pane)
                } else {
                    let captured = await tmuxService.capturePane(paneId: paneId, lines: Self.statusCaptureLines)
                    await reply(token: token, chatId: chatId, text: "<pre>\(escapeHTML(captured))</pre>", parseMode: "HTML")
                }
            }

        } else if data.hasPrefix("prompt_pane:") {
            let paneId = String(data.dropFirst("prompt_pane:".count))

            guard let text = pendingText else {
                await answerCallbackQuery(token: token, callbackQueryId: callback.id, text: "Message expired. Send again.")
                return
            }
            pendingText = nil

            let result = await tmuxService.sendKeys(paneId: paneId, text: text)
            switch result {
            case .success:
                await answerCallbackQuery(token: token, callbackQueryId: callback.id, text: "Sent!")
                let panes = await listAllClaudePanes()
                let label = panes.first(where: { $0.paneId == paneId })?.projectName ?? paneId
                await reply(token: token, chatId: chatId, text: "Sent to \(label) [\(paneId)]")
            case .failure(let error):
                await answerCallbackQuery(token: token, callbackQueryId: callback.id, text: "Failed")
                await reply(token: token, chatId: chatId, text: "Failed: \(error.message)")
            }

        } else {
            await answerCallbackQuery(token: token, callbackQueryId: callback.id, text: "Unknown action")
        }
    }

    // MARK: - Pane Resolution

    private struct PaneTarget {
        let sessionName: String
        let paneId: String
        let projectName: String?
    }

    private enum SendResult {
        case sent(paneId: String, session: String)
        case noneWaiting
        case multiple([PaneTarget])
        case error(String)
    }

    private func sendToWaitingPane(_ text: String) async -> SendResult {
        let panes = await listAllClaudePanes()
        if panes.isEmpty { return .noneWaiting }

        // Check which panes are waiting for input
        var waitingPanes: [PaneTarget] = []
        for pane in panes {
            let paneState = await tmuxService.detectPaneState(paneId: pane.paneId)
            if case .waitingForInput = paneState {
                waitingPanes.append(pane)
            }
        }

        if waitingPanes.isEmpty { return .noneWaiting }

        if waitingPanes.count == 1 {
            let target = waitingPanes[0]
            let result = await tmuxService.sendKeys(paneId: target.paneId, text: text)
            switch result {
            case .success:
                return .sent(paneId: target.paneId, session: target.projectName ?? target.sessionName)
            case .failure(let error):
                return .error(error.message)
            }
        }

        return .multiple(waitingPanes)
    }

    private func sendAsPrompt(token: String, chatId: String, text: String) async {
        let panes = await listAllClaudePanes()

        if panes.isEmpty {
            await reply(token: token, chatId: chatId, text: "No claude-* tmux sessions found. Start one with 'ca'.")
            return
        }

        if panes.count == 1 {
            let target = panes[0]
            let result = await tmuxService.sendKeys(paneId: target.paneId, text: text)
            switch result {
            case .success:
                let label = target.projectName ?? target.sessionName
                await reply(token: token, chatId: chatId, text: "Prompt sent to \(label) [\(target.paneId)]")
            case .failure(let error):
                await reply(token: token, chatId: chatId, text: "Failed: \(error.message)")
            }
            return
        }

        // Multiple panes - store text and show picker
        pendingText = text
        let buttons = panes.map { pane in
            let label = pane.projectName ?? pane.sessionName
            return (label: "\(label) [\(pane.paneId)]", data: "prompt_pane:\(pane.paneId)")
        }
        await replyWithInlineKeyboard(
            token: token,
            chatId: chatId,
            text: "Select session to send your message:",
            buttons: buttons
        )
    }

    private func listAllClaudePanes() async -> [PaneTarget] {
        let sessionList = await tmuxService.listSessions(prefix: Constants.tmuxSessionPrefix)

        var targets: [PaneTarget] = []
        for session in sessionList {
            let paneList = await tmuxService.listPanes(session: session.name)
            let project = await tmuxService.resolveProjectName(session: session.name)
            for pane in paneList {
                targets.append(PaneTarget(sessionName: session.name, paneId: pane.paneId, projectName: project))
            }
        }

        return targets
    }

    // MARK: - Reply Helpers

    private func replyMultiplePanes(token: String, chatId: String, panes: [PaneTarget], action: String) async {
        // Store the action text so the callback can send it
        pendingText = action
        let buttons = panes.map { pane in
            let label = pane.projectName ?? pane.sessionName
            return (label: "\(label) [\(pane.paneId)]", data: "prompt_pane:\(pane.paneId)")
        }
        await replyWithInlineKeyboard(
            token: token,
            chatId: chatId,
            text: "Multiple panes are waiting. Select where to send:",
            buttons: buttons
        )
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Telegram API Models

private struct InlineKeyboardMarkup: Encodable {
    let inline_keyboard: [[InlineKeyboardButton]]
}

private struct InlineKeyboardButton: Encodable {
    let text: String
    let callback_data: String
}

private struct TelegramGetUpdatesResponse: Decodable {
    let ok: Bool
    let result: [TelegramUpdate]
}

private struct TelegramUpdate: Decodable {
    let updateId: Int
    let message: TelegramMessage?
    let callbackQuery: TelegramCallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

private struct TelegramMessage: Decodable {
    let messageId: Int
    let from: TelegramUser?
    let chat: TelegramChat
    let text: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case from
        case chat
        case text
    }
}

private struct TelegramCallbackQuery: Decodable {
    let id: String
    let from: TelegramUser
    let data: String?
}

private struct TelegramUser: Decodable {
    let id: Int
}

private struct TelegramChat: Decodable {
    let id: Int
}

// MARK: - Errors

private enum PollingError: LocalizedError {
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .apiError(let code):
            return "Telegram API error (status \(code))"
        }
    }
}
