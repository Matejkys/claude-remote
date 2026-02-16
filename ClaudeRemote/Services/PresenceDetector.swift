import Foundation
import IOKit
import AppKit
import Observation

// Detects user presence using three independent signals:
// 1. IOKit HIDIdleTime - polled on a timer to detect keyboard/mouse inactivity
// 2. Screen lock/unlock - via DistributedNotificationCenter
// 3. Display sleep/wake - via NSWorkspace notifications
// Updates the AppState which determines the routing of notifications.
@MainActor
@Observable
final class PresenceDetector {
    private let appState: AppState
    private let settings: Settings
    private var pollingTimer: Timer?

    init(appState: AppState, settings: Settings) {
        self.appState = appState
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        startIdlePolling()
        registerScreenLockObservers()
        registerDisplaySleepObservers()
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - IOKit HID Idle Time Polling

    /// Queries IOKit for the system idle time (time since last user input event).
    /// Returns the idle duration in seconds, or nil if the query fails.
    private func querySystemIdleTime() -> TimeInterval? {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iterator
        )

        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        let propertiesResult = IORegistryEntryCreateCFProperties(
            entry,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        )

        guard propertiesResult == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
              let idleTimeNanoseconds = properties["HIDIdleTime"] as? Int64
        else {
            return nil
        }

        // HIDIdleTime is in nanoseconds, convert to seconds
        return TimeInterval(idleTimeNanoseconds) / 1_000_000_000.0
    }

    private func startIdlePolling() {
        // Perform an initial check immediately
        checkIdleTime()

        // Schedule recurring checks
        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.idlePollingIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkIdleTime()
            }
        }
    }

    private func checkIdleTime() {
        guard let idleSeconds = querySystemIdleTime() else {
            return
        }

        appState.isIdleTimerExpired = idleSeconds >= settings.idleThreshold
    }

    // MARK: - Screen Lock Detection

    /// Observes distributed notifications for screen lock/unlock events.
    /// These are system-wide notifications posted by loginwindow.
    private func registerScreenLockObservers() {
        let center = DistributedNotificationCenter.default()

        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appState.isScreenLocked = true
            }
        }

        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appState.isScreenLocked = false
                // Reset idle timer when unlocking since user is actively present
                self?.appState.isIdleTimerExpired = false
            }
        }
    }

    // MARK: - Display Sleep Detection

    /// Observes NSWorkspace notifications for display sleep/wake events.
    private func registerDisplaySleepObservers() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appState.isDisplayAsleep = true
            }
        }

        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appState.isDisplayAsleep = false
                // Reset idle timer when display wakes since user is actively present
                self?.appState.isIdleTimerExpired = false
            }
        }
    }
}
