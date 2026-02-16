import SwiftUI

// Main popover view displayed from the menu bar icon.
// Shows presence status, detection settings, notification preferences,
// Telegram configuration, and Claude Code / relay status.
struct MenuBarView: View {
    @Bindable var appState: AppState
    @Bindable var settings: Settings
    var onTestTelegram: () async -> Void
    var onKillSession: (String) -> Void
    var onCopyAttach: (String) -> Void
    var onQuit: () -> Void

    @State private var botTokenInput = ""
    @State private var userIDInput = ""
    @State private var showTelegramConfig = false
    @State private var isTesting = false
    @State private var copiedSession: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusHeader
                Divider()
                presenceSection
                Divider()
                notificationSection
                Divider()
                telegramSection
                Divider()
                sessionsSection
                Divider()
                claudeCodeSection
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

    // MARK: - Notifications

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("When at computer:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("macOS notification", isOn: $settings.notifyLocalWhenPresent)
                .toggleStyle(.checkbox)
                .padding(.leading, 4)
            Toggle("Sound", isOn: $settings.notifySoundWhenPresent)
                .toggleStyle(.checkbox)
                .padding(.leading, 4)

            Text("When away:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Telegram", isOn: $settings.notifyTelegramWhenAway)
                .toggleStyle(.checkbox)
                .padding(.leading, 4)
            Toggle("macOS notification", isOn: $settings.notifyLocalWhenAway)
                .toggleStyle(.checkbox)
                .padding(.leading, 4)
        }
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

    // MARK: - tmux Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("tmux Sessions")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(session.name)
                        .font(.system(.body, design: .monospaced))
                }
                Text("\(session.windows) window(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onCopyAttach(session.name)
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

            Button {
                onKillSession(session.name)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Kill session")
        }
        .padding(.vertical, 2)
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
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .toggleStyle(.checkbox)

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
