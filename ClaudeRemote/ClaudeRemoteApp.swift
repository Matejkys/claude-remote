import SwiftUI
import ServiceManagement

// ClaudeRemote - macOS menu bar app that routes Claude Code notifications
// locally (when at computer) or to Telegram (when away).
// Architecture: compact menu bar dropdown + standalone app window for full management.
@main
struct ClaudeRemoteApp: App {
    @State private var appController = AppController()

    var body: some Scene {
        // Compact menu bar dropdown (OrbStack-style)
        MenuBarExtra {
            MenuBarMenu(appController: appController)
                .task {
                    await appController.startServices()
                }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "circle.dotted.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(appController.appState.isAway ? .orange : .green)
                    .font(.system(size: 16))
            }
        }
        .menuBarExtraStyle(.menu)

        // Full app window opened on demand
        Window("Claude Remote", id: "main") {
            MainWindowView(appController: appController)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)

        // Settings window
        Window("Settings", id: "settings") {
            SettingsView(
                appState: appController.appState,
                settings: appController.settings,
                onTestTelegram: { await appController.testTelegramConnection() }
            )
        }
        .defaultSize(width: 400, height: 500)
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu Bar Dropdown

/// Compact menu with session list, quick actions, and app controls.
/// Uses .menu style which only supports Button/Toggle/Divider/Menu.
struct MenuBarMenu: View {
    let appController: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Open main app window
        Button("Open Claude Remote") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("n")

        Divider()

        // Session list
        if appController.appState.tmuxSessions.isEmpty {
            Button("No sessions running") {}
                .disabled(true)
        } else {
            ForEach(appController.appState.tmuxSessions) { session in
                sessionMenu(session)
            }
        }

        Divider()

        // Presence toggle
        if appController.settings.detectionMode == .manual {
            Toggle("Away", isOn: Binding(
                get: { appController.settings.manualAway },
                set: { appController.settings.manualAway = $0 }
            ))
        } else {
            Button("Status: \(appController.appState.statusDescription)") {}
                .disabled(true)
        }

        Divider()

        Button("Settings...") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func sessionMenu(_ session: AppState.TmuxSession) -> some View {
        Menu {
            Button("Open in App") {
                appController.selectedSessionId = session.name
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Copy Attach Command") {
                appController.tmuxMonitor?.copyAttachCommand(session.name)
            }

            Divider()

            Button("Kill Session") {
                Task { await appController.tmuxMonitor?.killSession(session.name) }
            }
        } label: {
            Text(sessionLabel(session))
        }
    }

    private func sessionLabel(_ session: AppState.TmuxSession) -> String {
        let name = session.displayName
        let state = session.state.displayName
        return "\(stateEmoji(session.state)) \(name) — \(state)"
    }

    private func stateEmoji(_ state: TmuxService.PaneState) -> String {
        switch state {
        case .active: return "🔵"
        case .waitingForInput: return "🟠"
        case .idle: return "⚪"
        case .unknown: return "⚫"
        }
    }
}

// MARK: - App Controller

/// Holds all services and manages their lifecycle.
@MainActor
@Observable
final class AppController {
    let settings = Settings()
    let appState: AppState
    let tmuxService = TmuxService()

    private var presenceDetector: PresenceDetector?
    private var telegramService: TelegramService?
    private var localNotifier: LocalNotifier?
    private var notificationRouter: NotificationRouter?
    private var httpListener: HTTPListener?
    private(set) var tmuxMonitor: TmuxMonitor?
    private var servicesStarted = false
    private var backgroundActivity: NSObjectProtocol?

    /// Selected session ID for navigation in main window
    var selectedSessionId: String?

    init() {
        self.appState = AppState(settings: settings)
    }

    func startServices() async {
        guard !servicesStarted else { return }
        servicesStarted = true

        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Listening for Claude Code notifications and routing to Telegram"
        )

        let telegram = TelegramService(settings: settings)
        let notifier = LocalNotifier(tmuxService: tmuxService)
        let router = NotificationRouter(
            appState: appState,
            settings: settings,
            telegramService: telegram,
            localNotifier: notifier
        )
        let listener = HTTPListener(appState: appState, settings: settings, router: router)
        let detector = PresenceDetector(appState: appState, settings: settings)
        let tmux = TmuxMonitor(appState: appState, tmuxService: tmuxService)

        self.telegramService = telegram
        self.localNotifier = notifier
        self.notificationRouter = router
        self.httpListener = listener
        self.presenceDetector = detector
        self.tmuxMonitor = tmux

        listener.start()
        detector.start()
        tmux.start()

        if settings.isTelegramConfigured {
            await checkTelegramStatus()
        }
    }

    func testTelegramConnection() async {
        guard let telegramService else { return }
        appState.telegramStatus = .checking
        do {
            let botName = try await telegramService.testConnection()
            appState.telegramStatus = .connected(botName: botName)
        } catch {
            appState.telegramStatus = .error(error.localizedDescription)
        }
    }

    private func checkTelegramStatus() async {
        guard let telegramService else { return }
        appState.telegramStatus = .checking
        do {
            let botName = try await telegramService.testConnection()
            appState.telegramStatus = .connected(botName: botName)
        } catch {
            appState.telegramStatus = .error(error.localizedDescription)
        }
    }

    func updateLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[App] Failed to update launch at login: \(error)")
        }
    }
}
