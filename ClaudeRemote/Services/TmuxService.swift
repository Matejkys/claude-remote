import Foundation
import AppKit

// Robust tmux interaction service with dynamic path discovery,
// proper async execution, error handling, and exit code checking.
// Replaces the fragile shell() helper from TmuxMonitor.
@MainActor
final class TmuxService {
    private let tmuxPath: String

    // MARK: - Initialization

    init() {
        self.tmuxPath = Self.discoverTmuxPath()
    }

    // MARK: - Path Discovery

    /// Searches common locations for the tmux binary, falling back to `which tmux`.
    private static func discoverTmuxPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/tmux",   // Homebrew on Apple Silicon
            "/usr/local/bin/tmux",      // Homebrew on Intel
            "/usr/bin/tmux",            // System tmux (older macOS)
            "/opt/local/bin/tmux",      // MacPorts
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Last resort: ask the shell
        if let resolved = try? Self.resolveViaWhich() {
            return resolved
        }

        // Fallback - will fail with a clear error when used
        return "/opt/homebrew/bin/tmux"
    }

    private static func resolveViaWhich() throws -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["tmux"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: - Core Execution

    /// Result of a tmux command execution
    struct CommandResult {
        let output: String
        let errorOutput: String
        let exitCode: Int32

        var succeeded: Bool { exitCode == 0 }
    }

    /// Runs a tmux command with proper async execution, pipe handling, and error capture.
    /// Reads pipes BEFORE waitUntilExit to prevent deadlocks on large output.
    func run(_ arguments: String...) async -> CommandResult {
        await run(arguments)
    }

    func run(_ arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: self.tmuxPath)
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    let result = CommandResult(
                        output: "",
                        errorOutput: "Failed to launch tmux at \(self.tmuxPath): \(error.localizedDescription)",
                        exitCode: -1
                    )
                    continuation.resume(returning: result)
                    return
                }

                // Read pipes FIRST to prevent deadlock when buffer fills
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()

                let output = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let result = CommandResult(
                    output: output,
                    errorOutput: errorOutput,
                    exitCode: process.terminationStatus
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Session Operations

    /// Lists all tmux sessions with structured data
    func listSessions() async -> [SessionInfo] {
        let result = await run(
            "list-sessions", "-F",
            "#{session_name}\t#{session_windows}\t#{session_created}\t#{session_activity}"
        )
        guard result.succeeded, !result.output.isEmpty else { return [] }

        return result.output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> SessionInfo? in
                let parts = line.components(separatedBy: "\t")
                guard let name = parts.first, !name.isEmpty else { return nil }
                let windows = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                let created = parts.count > 2 ? TimeInterval(parts[2]) ?? 0 : 0
                let lastActivity = parts.count > 3 ? TimeInterval(parts[3]) ?? 0 : 0
                return SessionInfo(
                    name: name,
                    windows: windows,
                    createdAt: Date(timeIntervalSince1970: created),
                    lastActivity: Date(timeIntervalSince1970: lastActivity)
                )
            }
    }

    /// Lists sessions matching a prefix (e.g., "claude-")
    func listSessions(prefix: String) async -> [SessionInfo] {
        let all = await listSessions()
        return all.filter { $0.name.hasPrefix(prefix) }
    }

    /// Kills a tmux session. Returns true on success, error message on failure.
    func killSession(_ name: String) async -> Result<Void, TmuxError> {
        let result = await run("kill-session", "-t", name)
        if result.succeeded {
            return .success(())
        } else {
            let msg = result.errorOutput.isEmpty
                ? "tmux exited with code \(result.exitCode)"
                : result.errorOutput
            return .failure(TmuxError(message: msg))
        }
    }

    /// Renames a tmux session
    func renameSession(_ name: String, to newName: String) async -> Result<Void, TmuxError> {
        let result = await run("rename-session", "-t", name, newName)
        if result.succeeded {
            return .success(())
        } else {
            let msg = result.errorOutput.isEmpty
                ? "tmux exited with code \(result.exitCode)"
                : result.errorOutput
            return .failure(TmuxError(message: msg))
        }
    }

    /// Sends keystrokes to a tmux pane (literal text + Enter)
    func sendKeys(paneId: String, text: String) async -> Result<Void, TmuxError> {
        // Send text literally (no shell interpretation)
        let sendResult = await run("send-keys", "-t", paneId, "-l", text)
        guard sendResult.succeeded else {
            let msg = sendResult.errorOutput.isEmpty
                ? "Failed to send keys (exit \(sendResult.exitCode))"
                : sendResult.errorOutput
            return .failure(TmuxError(message: msg))
        }

        // Send Enter to submit
        let enterResult = await run("send-keys", "-t", paneId, "Enter")
        guard enterResult.succeeded else {
            let msg = enterResult.errorOutput.isEmpty
                ? "Failed to send Enter (exit \(enterResult.exitCode))"
                : enterResult.errorOutput
            return .failure(TmuxError(message: msg))
        }

        return .success(())
    }

    /// Captures visible content from a tmux pane
    func capturePane(paneId: String, lines: Int = 50) async -> String {
        let result = await run("capture-pane", "-t", paneId, "-p", "-S", "-\(lines)")
        return result.output
    }

    /// Lists all pane IDs for a session
    func listPanes(session: String) async -> [PaneInfo] {
        let result = await run(
            "list-panes", "-t", session, "-F",
            "#{pane_id}\t#{pane_current_path}\t#{pane_active}"
        )
        guard result.succeeded, !result.output.isEmpty else { return [] }

        return result.output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> PaneInfo? in
                let parts = line.components(separatedBy: "\t")
                guard let paneId = parts.first, !paneId.isEmpty else { return nil }
                let path = parts.count > 1 ? parts[1] : ""
                let isActive = parts.count > 2 ? parts[2] == "1" : false
                return PaneInfo(
                    paneId: paneId,
                    currentPath: path,
                    isActive: isActive
                )
            }
    }

    /// Gets the project name for a session using multiple strategies
    func resolveProjectName(session: String) async -> String? {
        let panes = await listPanes(session: session)
        guard let firstPane = panes.first else { return nil }

        // Strategy 1: Try git root detection for accurate project name
        let gitResult = await runInPane(
            paneId: firstPane.paneId,
            command: "git rev-parse --show-toplevel 2>/dev/null"
        )
        if let gitRoot = gitResult, !gitRoot.isEmpty {
            let projectName = gitRoot.components(separatedBy: "/").last
            if let name = projectName, !name.isEmpty {
                return name
            }
        }

        // Strategy 2: Use pane's current working directory
        let path = firstPane.currentPath
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }

        let lastComponent = path.components(separatedBy: "/").last ?? ""

        // Skip generic directories
        let genericPaths = ["~", "", "tmp", "var", "private"]
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        if genericPaths.contains(lastComponent) || lastComponent == homeDir {
            return nil
        }

        return lastComponent
    }

    /// Runs a command inside a pane and captures the output.
    /// Used for git root detection etc. Does NOT send Enter - captures pane content.
    private func runInPane(paneId: String, command: String) async -> String? {
        // Use display-message with a format that runs a shell command
        let result = await run(
            "display-message", "-t", paneId, "-p",
            "#{pane_current_path}"
        )
        guard result.succeeded, !result.output.isEmpty else { return nil }

        // For git root: run git directly with the pane's working directory
        let panePath = result.output
        let gitProcess = Process()
        let pipe = Pipe()
        gitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitProcess.arguments = ["-C", panePath, "rev-parse", "--show-toplevel"]
        gitProcess.standardOutput = pipe
        gitProcess.standardError = FileHandle.nullDevice

        do {
            try gitProcess.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            gitProcess.waitUntilExit()
            guard gitProcess.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Session State Detection

    /// Known Claude Code prompt patterns indicating the terminal is waiting for input.
    /// Ported from telegram-relay/src/tmux.ts
    static let waitingPatterns: [(pattern: String, label: String)] = [
        // Permission prompts
        ("Allow once", "permission-prompt"),
        ("Allow always", "permission-prompt"),
        ("\\bDeny\\b", "permission-prompt"),
        ("Do you want to proceed", "confirmation-prompt"),
        ("\\(y/n\\)", "yes-no-prompt"),
        ("\\[Y/n\\]", "yes-no-prompt"),
        ("\\[y/N\\]", "yes-no-prompt"),
        ("approve", "approval-prompt"),

        // Claude Code tool approval
        ("Yes\\s*,?\\s*allow\\s+this", "permission-prompt"),
        ("No\\s*,?\\s*deny\\s+this", "permission-prompt"),

        // Question/input prompts
        ("\\?\\s*$", "question-prompt"),
        ("^\\s*\\d+\\.\\s+.+", "numbered-options"),
        ("Enter your (choice|answer|response)", "input-prompt"),
        ("Type your (message|response|answer)", "input-prompt"),
        ("Please (choose|select|enter|type|provide)", "input-prompt"),
    ]

    /// Patterns indicating the terminal is idle (shell prompt visible)
    static let idlePatterns: [(pattern: String, label: String)] = [
        ("\\$\\s*$", "shell-prompt"),
        (">\\s*$", "shell-prompt"),
        ("❯\\s*$", "shell-prompt"),
        ("➜\\s*$", "shell-prompt"),
    ]

    /// Detects the state of a pane by analyzing its terminal content
    func detectPaneState(paneId: String) async -> PaneState {
        let content = await capturePane(paneId: paneId, lines: 20)
        let lines = content.components(separatedBy: "\n")
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let lastLines = nonEmptyLines.suffix(10).joined(separator: "\n")

        // Check waiting patterns
        for (pattern, label) in Self.waitingPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: lastLines, range: NSRange(lastLines.startIndex..., in: lastLines)) != nil {
                return .waitingForInput(matchedPattern: label)
            }
        }

        // Check idle patterns
        for (pattern, label) in Self.idlePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: lastLines, range: NSRange(lastLines.startIndex..., in: lastLines)) != nil {
                return .idle(matchedPattern: label)
            }
        }

        // If there's content but no recognized pattern, assume active
        if !lastLines.isEmpty {
            return .active
        }

        return .unknown
    }

    /// Detects the overall state of a session by checking its panes
    func detectSessionState(session: String) async -> PaneState {
        let panes = await listPanes(session: session)
        guard !panes.isEmpty else { return .unknown }

        // Check the first (main) pane for state
        return await detectPaneState(paneId: panes[0].paneId)
    }

    // MARK: - Clipboard

    /// Copies the tmux attach command to the system clipboard
    func copyAttachCommand(_ sessionName: String) {
        let command = "tmux attach-session -t \(sessionName)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

// MARK: - Data Types

extension TmuxService {
    struct SessionInfo {
        let name: String
        let windows: Int
        let createdAt: Date
        let lastActivity: Date
    }

    struct PaneInfo: Equatable {
        let paneId: String
        let currentPath: String
        let isActive: Bool
    }

    /// Error type for tmux operations
    struct TmuxError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum PaneState: Equatable {
        case active
        case waitingForInput(matchedPattern: String)
        case idle(matchedPattern: String)
        case unknown

        var displayName: String {
            switch self {
            case .active: return "Active"
            case .waitingForInput: return "Waiting"
            case .idle: return "Idle"
            case .unknown: return "Unknown"
            }
        }

        var isWaiting: Bool {
            if case .waitingForInput = self { return true }
            return false
        }
    }
}
