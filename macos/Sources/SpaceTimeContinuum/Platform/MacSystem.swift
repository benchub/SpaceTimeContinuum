import AppKit
import CoreGraphics
import ServiceManagement
import STCCore
import UserNotifications

/// Screen-on and unlocked state, polled once per second by the recorder.
final class MacSessionState: SessionStateProviding {
    private var displaysAsleep = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaysAsleep = true
        })
        observers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaysAsleep = false
        })
    }

    var isScreenOn: Bool {
        guard !displaysAsleep else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }

    var isUnlocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let onConsole = dict[kCGSessionOnConsoleKey as String] as? Bool ?? true
        let locked = dict["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && !locked
    }
}

final class MacLoginItem: LoginItemManaging {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

final class MacNotifier: Notifying {
    /// UNUserNotificationCenter crashes when not running from an .app bundle (e.g. `swift run`).
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Whether macOS will actually show our notifications (always true when not running as an .app).
    func checkAllowed(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard available else { completion(true); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            let allowed = status == .notDetermined || ((status == .authorized || status == .provisional) && settings.alertSetting != .disabled)
            completion(allowed)
        }
    }

    func notify(title: String, body: String) {
        guard available else {
            NSLog("Notification: %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
