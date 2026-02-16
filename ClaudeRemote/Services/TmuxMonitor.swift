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

        return output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty && $0.hasPrefix(Constants.tmuxSessionPrefix) }
            .map { line in
                let parts = line.components(separatedBy: "\t")
                let name = parts.first ?? ""
                let windows = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                let created = parts.count > 2 ? parts[2] : ""
                return AppState.TmuxSession(name: name, windows: windows, created: created)
            }
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
