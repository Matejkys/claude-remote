import SwiftUI
import ServiceManagement

// ClaudeRemote - macOS menu bar app that routes Claude Code notifications
// locally (when at computer) or to Telegram (when away).
// Architecture: rich popover from menu bar icon + standalone app window for full management.
@main
struct ClaudeRemoteApp: App {
    @State private var appController = AppController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Rich popover from menu bar icon
        MenuBarExtra {
            MenuBarPopover(
                appState: appController.appState,
                settings: appController.settings,
                tmuxMonitor: appController.tmuxMonitor,
                onOpenApp: { sessionId in
                    appController.selectedSessionId = sessionId
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                },
                onOpenSettings: {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .frame(width: 340)
            .task {
                await appController.startServices()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "circle.dotted.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(appController.appState.isAway ? .orange : .green)
                    .font(.system(size: 16))

                if appController.appState.waitingSessionCount > 0 {
                    Text("\(appController.appState.waitingSessionCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .menuBarExtraStyle(.window)

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
