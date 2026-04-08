import SwiftUI

// Detail panel for a single tmux session shown in the main window's detail area.
// Shows terminal preview, input field, quick actions, and session management.
struct SessionDetailView: View {
    let session: AppState.TmuxSession
    let tmuxMonitor: TmuxMonitor

    @State private var terminalContent = ""
    @State private var inputText = ""
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showKillConfirmation = false
    @State private var refreshTimer: Timer?
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header toolbar
            headerBar

            Divider()

            // Main content
            HSplitView {
                // Terminal preview (left/main area)
                terminalArea
                    .frame(minWidth: 300)

                // Side panel with actions and info
                sidePanel
                    .frame(width: 220)
            }
        }
        .task {
            await refreshTerminal()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .onChange(of: session.name) { _, _ in
            // Refresh when switching sessions
            Task { await refreshTerminal() }
        }
        .alert("Kill Session", isPresented: $showKillConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Kill", role: .destructive) {
                Task { await tmuxMonitor.killSession(session.name) }
            }
        } message: {
            Text("Kill session '\(session.displayName)'?\nThis will terminate Claude Code running in it.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            if isRenaming {
                TextField("Session name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .frame(maxWidth: 250)
                    .onSubmit { submitRename() }

                Button("Save") { submitRename() }
                    .disabled(renameText.isEmpty || renameText == session.name)
                Button("Cancel") { isRenaming = false }
            } else {
                Text(session.displayName)
                    .font(.title3.bold())

                stateLabel

                if session.projectName != nil {
                    Text(session.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Header actions
            Button {
                renameText = session.name
                isRenaming = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("Rename session")

            Button {
                tmuxMonitor.copyAttachCommand(session.name)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy attach command")

            Button {
                showKillConfirmation = true
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
            .help("Kill session")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var stateLabel: some View {
        Text(session.state.displayName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor.opacity(0.15))
            .clipShape(Capsule())
            .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch session.state {
        case .active: return .blue
        case .waitingForInput: return .orange
        case .idle: return .gray
        case .unknown: return .gray.opacity(0.5)
        }
    }

    // MARK: - Terminal Area

    private var terminalArea: some View {
        VStack(spacing: 0) {
            // Terminal header
            HStack {
                Text("Terminal")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await refreshTerminal() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Terminal content
            ScrollView {
                ScrollViewReader { proxy in
                    Text(terminalContent.isEmpty ? "Loading..." : terminalContent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .init(red: 0.83, green: 0.83, blue: 0.83, alpha: 1)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                        .id("terminal-end")
                        .onChange(of: terminalContent) { _, _ in
                            proxy.scrollTo("terminal-end", anchor: .bottom)
                        }
                }
            }
            .background(Color(nsColor: .init(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)))

            Divider()

            // Input area
            HStack(spacing: 8) {
                TextField("Send input to session...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { sendInput() }

                Button("Send") { sendInput() }
                    .disabled(inputText.isEmpty || session.panes.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)
        }
    }

    // MARK: - Side Panel

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                quickActionsSection
                Divider()
                sessionInfoSection
            }
            .padding(12)
        }
        .background(.background.secondary)
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                quickButton(label: "Approve", text: "y", color: .green)
                quickButton(label: "Deny", text: "n", color: .red)
            }

            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { i in
                    quickButton(label: "\(i)", text: "\(i)", color: .blue)
                }
            }
        }
    }

    private func quickButton(label: String, text: String, color: Color) -> some View {
        Button(label) {
            Task {
                guard let pane = session.panes.first else { return }
                await tmuxMonitor.sendInput(paneId: pane.paneId, text: text)
                try? await Task.sleep(for: .seconds(1))
                await refreshTerminal()
            }
        }
        .buttonStyle(.bordered)
        .tint(color)
        .controlSize(.small)
        .disabled(session.panes.isEmpty)
    }

    // MARK: - Session Info

    private var sessionInfoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session Info")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            infoRow("Session", session.name)
            if let project = session.projectName {
                infoRow("Project", project)
            }
            infoRow("Windows", "\(session.windows)")
            infoRow("Panes", "\(session.panes.count)")
            infoRow("Created", session.createdFormatted)
            if let firstPane = session.panes.first, !firstPane.currentPath.isEmpty {
                infoRow("Path", firstPane.currentPath)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Actions

    private func refreshTerminal() async {
        guard let pane = session.panes.first else { return }
        isRefreshing = true
        terminalContent = await tmuxMonitor.tmuxService.capturePane(
            paneId: pane.paneId,
            lines: Constants.terminalPreviewLines
        )
        isRefreshing = false
    }

    private func sendInput() {
        guard !inputText.isEmpty, let pane = session.panes.first else { return }
        let text = inputText
        inputText = ""
        Task {
            await tmuxMonitor.sendInput(paneId: pane.paneId, text: text)
            try? await Task.sleep(for: .seconds(1))
            await refreshTerminal()
        }
    }

    private func submitRename() {
        guard !renameText.isEmpty, renameText != session.name else {
            isRenaming = false
            return
        }
        let newName = renameText
        isRenaming = false
        Task { await tmuxMonitor.renameSession(session.name, to: newName) }
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.terminalPreviewRefreshSeconds,
            repeats: true
        ) { _ in
            Task { @MainActor in
                await refreshTerminal()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
