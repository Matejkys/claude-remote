import SwiftUI
import ServiceManagement

// Standalone settings window with presence detection, Telegram config,
// and Claude Code status. Opened from menu bar via "Settings...".
struct SettingsView: View {
    @Bindable var appState: AppState
    @Bindable var settings: Settings
    var onTestTelegram: () async -> Void

    @State private var botTokenInput = ""
    @State private var userIDInput = ""
    @State private var showTelegramConfig = false
    @State private var isTesting = false

    var body: some View {
        Form {
            presenceSection
            telegramSection
            claudeCodeSection
            appSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 450)
        .navigationTitle("Settings")
    }

    // MARK: - Presence Detection

    private var presenceSection: some View {
        Section("Presence Detection") {
            Picker("Mode", selection: $settings.detectionMode) {
                Text("Automatic").tag(DetectionMode.automatic)
                Text("Manual").tag(DetectionMode.manual)
            }

            if settings.detectionMode == .automatic {
                Picker("Idle threshold", selection: $settings.idleThreshold) {
                    ForEach(Constants.idleThresholdOptions, id: \.self) { seconds in
                        Text(formatDuration(seconds)).tag(seconds)
                    }
                }

                Toggle("Screen lock = away", isOn: $settings.screenLockAway)
                Toggle("Display sleep = away", isOn: $settings.displaySleepAway)
            } else {
                Toggle("I'm away", isOn: $settings.manualAway)
            }
        }
    }

    // MARK: - Telegram

    private var telegramSection: some View {
        Section("Telegram") {
            telegramStatusRow

            if showTelegramConfig {
                TextField("Bot Token", text: $botTokenInput)
                    .font(.system(.body, design: .monospaced))

                TextField("User ID", text: $userIDInput)
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
            } else {
                Button("Configure...") {
                    botTokenInput = settings.telegramBotToken ?? ""
                    userIDInput = settings.telegramUserID ?? ""
                    showTelegramConfig = true
                }
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
                Text("Connected — \(botName)")
            case .error(let message):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Claude Code

    private var claudeCodeSection: some View {
        Section("Claude Code") {
            LabeledContent("tmux session") {
                Text(settings.tmuxSessionName)
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("HTTP Listener") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.httpListenerRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(appState.httpListenerRunning ? "Running on :\(Constants.httpListenerPort)" : "Stopped")
                }
            }
        }
    }

    // MARK: - App

    private var appSection: some View {
        Section("App") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .onChange(of: settings.launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("[Settings] Failed to update launch at login: \(error)")
                    }
                }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes == 1 { return "1 minute" }
        return "\(minutes) minutes"
    }
}
