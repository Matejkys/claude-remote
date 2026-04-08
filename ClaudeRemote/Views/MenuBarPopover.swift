import SwiftUI

// Rich popover view for the menu bar icon.
// Shows session list with colored state dots, age, quick action icons.
// Compact design - no navigation, opens main app window for details.
struct MenuBarPopover: View {
    @Bindable var appState: AppState
    @Bindable var settings: Settings
    var tmuxMonitor: TmuxMonitor?
    var onOpenApp: (_ sessionId: String?) -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var copiedSession: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusHeader
                feedbackBanner
                Divider()
                sessionsSection
                Divider()
                footerSection
            }
            .padding(16)
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(appState.isAway ? Color.orange : Color.green)
                .frame(width: 10, height: 10)
            Text("Status: \(appState.statusDescription)")
                .font(.headline)
            Spacer()
            if appState.activeSessionCount > 0 {
                Text("\(appState.activeSessionCount) session\(appState.activeSessionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Feedback Banner

    @ViewBuilder
    private var feedbackBanner: some View {
        if let error = appState.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button {
                    appState.errorMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }

        if let success = appState.successMessage {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(success)
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
            }
            .padding(8)
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.waitingSessionCount > 0 {
                    Text("\(appState.waitingSessionCount) waiting")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(.orange)
                }
                Button {
                    tmuxMonitor?.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh sessions")
            }

            if appState.tmuxSessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                    Text("No claude-* sessions running")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } else {
                ForEach(appState.tmuxSessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: AppState.TmuxSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(stateColor(session.state))
                        .frame(width: 6, height: 6)
                    Text(session.displayName)
                        .font(.system(.body, design: .monospaced))
                }
                HStack(spacing: 4) {
                    Text(session.state.displayName)
                        .foregroundStyle(stateColor(session.state))
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(session.createdFormatted)
                        .foregroundStyle(.secondary)
                    if session.projectName != nil {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(session.name)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
            }
            Spacer()

            // Open in App
            Button {
                onOpenApp(session.name)
            } label: {
                Image(systemName: "macwindow")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Open in app")

            // Copy attach command
            Button {
                tmuxMonitor?.copyAttachCommand(session.name)
                copiedSession = session.name
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedSession == session.name {
                        copiedSession = nil
                    }
                }
            } label: {
                if copiedSession == session.name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "doc.on.doc")
                }
            }
            .buttonStyle(.borderless)
            .help("Copy attach command")

            // Kill session (direct, no confirmation in popover)
            Button {
                Task { await tmuxMonitor?.killSession(session.name) }
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Kill session")
        }
        .padding(.vertical, 2)
    }

    private func stateColor(_ state: TmuxService.PaneState) -> Color {
        switch state {
        case .active: return .blue
        case .waitingForInput: return .orange
        case .idle: return .gray
        case .unknown: return .gray.opacity(0.5)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                onOpenApp(nil)
            } label: {
                Label("Open App", systemImage: "macwindow")
            }
            .buttonStyle(.link)

            Spacer()

            Button("Settings...") {
                onOpenSettings()
            }
            .buttonStyle(.link)

            Spacer()

            Button("Quit") {
                onQuit()
            }
            .buttonStyle(.link)
            .foregroundStyle(.red)
        }
    }
}
