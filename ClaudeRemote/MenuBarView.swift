import SwiftUI

// Main popover view displayed from the menu bar icon.
// Uses NavigationStack for session list → detail navigation.
// Shows presence status, session manager, Telegram config, and app settings.
struct MenuBarView: View {
    @Bindable var appState: AppState
    @Bindable var settings: Settings
    var tmuxMonitor: TmuxMonitor?
    var onTestTelegram: () async -> Void
    var onQuit: () -> Void

    @State private var botTokenInput = ""
    @State private var userIDInput = ""
    @State private var showTelegramConfig = false
    @State private var isTesting = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusHeader
                    feedbackBanner
                    Divider()
                    sessionsSection
                    Divider()
                    if showSettings {
                        presenceSection
                        Divider()
                        telegramSection
                        Divider()
                        claudeCodeSection
                        Divider()
                    }
                    footerSection
                }
                .padding(16)
            }
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

    // MARK: - Sessions Section

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
                    NavigationLink {
                        if let monitor = tmuxMonitor {
                            SessionDetailView(session: session, tmuxMonitor: monitor)
                        }
                    } label: {
                        SessionRowView(
                            session: session,
                            onCopyAttach: { tmuxMonitor?.copyAttachCommand(session.name) },
                            onKill: {
                                Task { await tmuxMonitor?.killSession(session.name) }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Presence Detection

    private var presenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presence Detection")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $settings.detectionMode) {
                Text("Automatic").tag(DetectionMode.automatic)
                Text("Manual").tag(DetectionMode.manual)
            }
            .pickerStyle(.segmented)

            if settings.detectionMode == .automatic {
                automaticDetectionOptions
            } else {
                manualDetectionOptions
            }
        }
    }

    private var automaticDetectionOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Idle threshold:")
                Picker("", selection: $settings.idleThreshold) {
                    ForEach(Constants.idleThresholdOptions, id: \.self) { seconds in
                        Text(formatDuration(seconds)).tag(seconds)
                    }
                }
                .frame(width: 120)
            }

            Toggle("Screen lock = away", isOn: $settings.screenLockAway)
                .toggleStyle(.checkbox)
            Toggle("Display sleep = away", isOn: $settings.displaySleepAway)
                .toggleStyle(.checkbox)
        }
        .padding(.leading, 4)
    }

    private var manualDetectionOptions: some View {
        Toggle("I'm away", isOn: $settings.manualAway)
            .toggleStyle(.checkbox)
            .padding(.leading, 4)
    }

    // MARK: - Telegram

    private var telegramSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Telegram")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            telegramStatusRow

            if showTelegramConfig {
                telegramConfigFields
            } else {
                Button("Configure...") {
                    botTokenInput = settings.telegramBotToken ?? ""
                    userIDInput = settings.telegramUserID ?? ""
                    showTelegramConfig = true
                }
                .buttonStyle(.link)
            }
        }
    }

    private var telegramStatusRow: some View {
        HStack(spacing: 6) {
            switch appState.telegramStatus {
            case .notConfigured:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text("Not configured")
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView()
                    .scaleEffect(0.6)
                Text("Checking...")
                    .foregroundStyle(.secondary)
            case .connected(let botName):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected")
                Text(botName)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .font(.caption)
            }
        }
    }

    private var telegramConfigFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Bot Token", text: $botTokenInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            TextField("User ID", text: $userIDInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Button("Save & Test") {
                    settings.telegramBotToken = botTokenInput.isEmpty ? nil : botTokenInput
                    settings.telegramUserID = userIDInput.isEmpty ? nil : userIDInput
                    isTesting = true
                    Task {
                        await onTestTelegram()
                        isTesting = false
                        if case .connected = appState.telegramStatus {
                            showTelegramConfig = false
                        }
                    }
                }
                .disabled(botTokenInput.isEmpty || userIDInput.isEmpty || isTesting)

                Button("Cancel") {
                    showTelegramConfig = false
                }
            }
        }
    }

    // MARK: - Claude Code Status

    private var claudeCodeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Text("tmux session:")
                    .foregroundStyle(.secondary)
                Text(settings.tmuxSessionName)
                    .font(.system(.body, design: .monospaced))
            }

            HStack {
                Text("HTTP Listener:")
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(appState.httpListenerRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.httpListenerRunning ? "Running" : "Stopped")
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    showSettings.toggle()
                } label: {
                    Label(showSettings ? "Hide Settings" : "Settings...", systemImage: "gear")
                }
                .buttonStyle(.link)

                Spacer()

                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.checkbox)
            }

            Button("Quit Claude Remote") {
                onQuit()
            }
            .buttonStyle(.link)
            .foregroundStyle(.red)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes == 1 {
            return "1 minute"
        }
        return "\(minutes) minutes"
    }
}
