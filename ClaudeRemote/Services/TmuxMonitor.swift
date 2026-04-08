import Foundation
import AppKit

// Periodically scans for tmux sessions matching the claude-* prefix.
// Uses TmuxService for all tmux operations with proper error handling.
// Provides session management actions (kill, rename, send input).
@MainActor
final class TmuxMonitor {
    private let appState: AppState
    let tmuxService: TmuxService
    private var pollingTimer: Timer?

    init(appState: AppState, tmuxService: TmuxService) {
        self.appState = appState
        self.tmuxService = tmuxService
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
        let sessionInfos = await tmuxService.listSessions(prefix: Constants.tmuxSessionPrefix)
        guard !sessionInfos.isEmpty else { return [] }

        var results: [AppState.TmuxSession] = []

        for info in sessionInfos {
            let projectName = await tmuxService.resolveProjectName(session: info.name)
            let state = await tmuxService.detectSessionState(session: info.name)
            let panes = await tmuxService.listPanes(session: info.name)

            results.append(AppState.TmuxSession(
                name: info.name,
                windows: info.windows,
                createdAt: info.createdAt,
                lastActivity: info.lastActivity,
                projectName: projectName,
                state: state,
                panes: panes
            ))
        }

        return results
    }

    // MARK: - Actions

    /// Kills a tmux session by name. Reports success/failure to UI.
    func killSession(_ name: String) async {
        let result = await tmuxService.killSession(name)
        switch result {
        case .success:
            appState.showSuccess("Session '\(name)' killed")
            refresh()
        case .failure(let error):
            appState.showError("Failed to kill '\(name)': \(error)")
        }
    }

    /// Renames a tmux session. Reports success/failure to UI.
    func renameSession(_ name: String, to newName: String) async {
        let result = await tmuxService.renameSession(name, to: newName)
        switch result {
        case .success:
            appState.showSuccess("Session renamed to '\(newName)'")
            refresh()
        case .failure(let error):
            appState.showError("Failed to rename: \(error)")
        }
    }

    /// Sends input to a pane. Reports success/failure to UI.
    func sendInput(paneId: String, text: String) async {
        let result = await tmuxService.sendKeys(paneId: paneId, text: text)
        switch result {
        case .success:
            appState.showSuccess("Input sent")
        case .failure(let error):
            appState.showError("Failed to send input: \(error)")
        }
    }

    /// Copies the tmux attach command to the system clipboard
    func copyAttachCommand(_ name: String) {
        tmuxService.copyAttachCommand(name)
        appState.showSuccess("Copied attach command")
    }
}
