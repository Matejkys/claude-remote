import SwiftUI

// Full app window with sidebar session list and detail panel.
// Opened from menu bar via "Open Claude Remote".
struct MainWindowView: View {
    let appController: AppController

    @State private var selectedSession: AppState.TmuxSession?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPanel
        }
        .frame(minWidth: 700, minHeight: 400)
        .onChange(of: appController.selectedSessionId) { _, newId in
            if let id = newId,
               let session = appController.appState.tmuxSessions.first(where: { $0.name == id }) {
                selectedSession = session
                appController.selectedSessionId = nil
            }
        }
        .onChange(of: appController.appState.tmuxSessions) { _, sessions in
            // Keep selection in sync when sessions refresh
            if let selected = selectedSession {
                selectedSession = sessions.first(where: { $0.name == selected.name })
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedSession) {
                Section {
                    ForEach(appController.appState.tmuxSessions) { session in
                        SidebarSessionRow(session: session)
                            .tag(session)
                    }
                } header: {
                    HStack {
                        Text("Sessions")
                        Spacer()
                        Text("\(appController.appState.activeSessionCount)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Button {
                            appController.tmuxMonitor?.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.sidebar)

            // Status bar at bottom of sidebar
            HStack(spacing: 6) {
                Circle()
                    .fill(appController.appState.isAway ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(appController.appState.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if appController.appState.waitingSessionCount > 0 {
                    Text("\(appController.appState.waitingSessionCount) waiting")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let session = selectedSession, let monitor = appController.tmuxMonitor {
            SessionDetailView(session: session, tmuxMonitor: monitor)
        } else {
            ContentUnavailableView {
                Label("No Session Selected", systemImage: "rectangle.on.rectangle.slash")
            } description: {
                if appController.appState.tmuxSessions.isEmpty {
                    Text("No claude-* tmux sessions are running.")
                } else {
                    Text("Select a session from the sidebar to view details.")
                }
            }
        }
    }
}

// MARK: - Sidebar Row

struct SidebarSessionRow: View {
    let session: AppState.TmuxSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("\(session.state.displayName) · \(session.createdFormatted)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var stateColor: Color {
        switch session.state {
        case .active: return .blue
        case .waitingForInput: return .orange
        case .idle: return .gray
        case .unknown: return .gray.opacity(0.5)
        }
    }
}
