import SwiftUI

// Detail view for a single tmux session.
// Shows terminal preview, session info, input field, and management actions.
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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                Divider()
                terminalPreview
                Divider()
                inputSection
                Divider()
                quickActions
                Divider()
                sessionInfoSection
                Divider()
                managementActions
            }
            .padding(16)
        }
        .frame(width: 420, height: 600)
        .task {
            await refreshTerminal()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .alert("Kill Session", isPresented: $showKillConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Kill", role: .destructive) {
                Task {
                    await tmuxMonitor.killSession(session.name)
                    dismiss()
                }
            }
        } message: {
            Text("Kill session '\(session.displayName)'? This will terminate Claude Code running in it.")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    HStack {
                        TextField("Session name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: 200)
                            .onSubmit { submitRename() }

                        Button("Save") { submitRename() }
                            .disabled(renameText.isEmpty || renameText == session.name)

                        Button("Cancel") { isRenaming = false }
                    }
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(stateColor)
                            .frame(width: 10, height: 10)
                        Text(session.displayName)
                            .font(.headline)
                        Text(session.state.displayName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(stateColor.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(stateColor)
                    }
                }
            }
            Spacer()
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .active: return .blue
        case .waitingForInput: return .orange
        case .idle: return .gray
        case .unknown: return .gray.opacity(0.5)
        }
    }

    // MARK: - Terminal Preview

    private var terminalPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Terminal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await refreshTerminal() }
                } label: {
                    Image(systemName: isRefreshing ? "arrow.clockwise" : "arrow.clockwise")
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 0.5).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
                .buttonStyle(.borderless)
                .help("Refresh terminal")
            }

            ScrollView(.vertical) {
                ScrollViewReader { proxy in
                    Text(terminalContent.isEmpty ? "Loading..." : terminalContent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .init(red: 0.83, green: 0.83, blue: 0.83, alpha: 1)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("terminal-bottom")
                        .onChange(of: terminalContent) { _, _ in
                            proxy.scrollTo("terminal-bottom", anchor: .bottom)
                        }
                }
            }
            .frame(height: 200)
            .background(Color(nsColor: .init(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Input Section

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Send Input")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Type a message...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { sendInput() }

                Button("Send") { sendInput() }
                    .disabled(inputText.isEmpty || session.panes.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Actions")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                quickActionButton(label: "Approve (y)", text: "y", color: .green)
                quickActionButton(label: "Deny (n)", text: "n", color: .red)
                quickActionButton(label: "Yes", text: "yes", color: .green)
                quickActionButton(label: "No", text: "no", color: .red)
            }

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { i in
                    quickActionButton(label: "\(i)", text: "\(i)", color: .blue)
                }
            }
        }
    }

    private func quickActionButton(label: String, text: String, color: Color) -> some View {
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Session Info")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            infoRow(label: "Session", value: session.name)
            if let project = session.projectName {
                infoRow(label: "Project", value: project)
            }
            infoRow(label: "Windows", value: "\(session.windows)")
            infoRow(label: "Panes", value: "\(session.panes.count)")
            infoRow(label: "Created", value: session.createdFormatted)
            if let firstPane = session.panes.first, !firstPane.currentPath.isEmpty {
                infoRow(label: "Working Dir", value: firstPane.currentPath)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .font(.caption)
    }

    // MARK: - Management Actions

    private var managementActions: some View {
        HStack(spacing: 12) {
            Button {
                renameText = session.name
                isRenaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .buttonStyle(.bordered)

            Button {
                tmuxMonitor.copyAttachCommand(session.name)
            } label: {
                Label("Copy Attach", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                showKillConfirmation = true
            } label: {
                Label("Kill Session", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .tint(.red)
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
        Task {
            await tmuxMonitor.renameSession(session.name, to: newName)
        }
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
