import Foundation
import AppKit

// Periodically scans for tmux sessions matching the claude-* prefix.
// Updates AppState with the list of active sessions.
// Provides actions to kill sessions or copy attach commands to clipboard.
@MainActor
final class TmuxMonitor {
    private let appState: AppState
    private var pollingTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Lifecycle

    func start() {
        refresh()
        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.tmuxPollingIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // MARK: - Refresh

    func refresh() {
        Task {
            let sessions = await scanSessions()
            appState.tmuxSessions = sessions
        }
    }

    // MARK: - Scan

    private func scanSessions() async -> [AppState.TmuxSession] {
        let output = await shell(Constants.tmuxPath, "list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_created_string}")
        guard !output.isEmpty else { return [] }

        let sessions = output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty && $0.hasPrefix(Constants.tmuxSessionPrefix) }
            .map { line -> (name: String, windows: Int, created: String) in
                let parts = line.components(separatedBy: "\t")
                let name = parts.first ?? ""
                let windows = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                let created = parts.count > 2 ? parts[2] : ""
                return (name: name, windows: windows, created: created)
            }

        // Resolve project names from first pane's working directory
        var results: [AppState.TmuxSession] = []
        for session in sessions {
            let projectName = await getSessionProjectName(session.name)
            results.append(AppState.TmuxSession(
                name: session.name,
                windows: session.windows,
                created: session.created,
                projectName: projectName
            ))
        }
        return results
    }

    /// Gets the project name from the first pane's working directory in a session
    private func getSessionProjectName(_ sessionName: String) async -> String? {
        let output = await shell(Constants.tmuxPath, "list-panes", "-t", sessionName, "-F", "#{pane_current_path}")
        guard !output.isEmpty else { return nil }
        // Take the first pane's path
        let path = output.components(separatedBy: "\n").first ?? ""
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }
        return path.components(separatedBy: "/").last
    }

    // MARK: - Actions

    /// Kills a tmux session by name
    func killSession(_ name: String) {
        Task {
            _ = await shell(Constants.tmuxPath, "kill-session", "-t", name)
            refresh()
        }
    }

    /// Copies the tmux attach command to the system clipboard
    func copyAttachCommand(_ name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "tmux attach-session -t \(cleanName)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    // MARK: - Shell Helper

    private func shell(_ command: String, _ arguments: String...) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
