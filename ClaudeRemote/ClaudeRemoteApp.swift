import SwiftUI
import ServiceManagement

// ClaudeRemote - macOS menu bar app that routes Claude Code notifications
// locally (when at computer) or to Telegram (when away).
// Runs as a menu bar-only app (LSUIElement = true, no Dock icon).
@main
struct ClaudeRemoteApp: App {
    @State private var appController = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                appState: appController.appState,
                settings: appController.settings,
                onTestTelegram: { await appController.testTelegramConnection() },
                onKillSession: { name in appController.tmuxMonitor?.killSession(name) },
                onCopyAttach: { name in appController.tmuxMonitor?.copyAttachCommand(name) },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .frame(width: 320)
            .task {
                await appController.startServices()
            }
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .symbolRenderingMode(.palette)
                .foregroundStyle(appController.appState.isAway ? .orange : .green)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: appController.settings.launchAtLogin) { _, newValue in
            appController.updateLaunchAtLogin(enabled: newValue)
        }
    }
}

// Holds all services and manages their lifecycle.
// Separated from App struct because Scene doesn't support .task directly.
@MainActor
@Observable
final class AppController {
    let settings = Settings()
    let appState: AppState

    private var presenceDetector: PresenceDetector?
    private var telegramService: TelegramService?
    private var localNotifier: LocalNotifier?
    private var notificationRouter: NotificationRouter?
    private var httpListener: HTTPListener?
    private(set) var tmuxMonitor: TmuxMonitor?
    private var servicesStarted = false

    init() {
        self.appState = AppState(settings: settings)
    }

    func startServices() async {
        guard !servicesStarted else { return }
        servicesStarted = true

        let telegram = TelegramService(settings: settings)
        let notifier = LocalNotifier()
        let router = NotificationRouter(
            appState: appState,
            settings: settings,
            telegramService: telegram,
            localNotifier: notifier
        )
        let listener = HTTPListener(appState: appState, settings: settings, router: router)
        let detector = PresenceDetector(appState: appState, settings: settings)
        let tmux = TmuxMonitor(appState: appState)

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
