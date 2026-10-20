import Foundation
import STCCore

/// Screen-on and unlocked state. The recorder polls this every second, so the slow parts
/// (asking logind) are refreshed in the background every few seconds and cached.
final class LinuxSessionState: SessionStateProviding {
    private let lock = NSLock()
    private var cachedUnlocked = true
    private var timer: DispatchSourceTimer?

    init() {
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    /// Any connected DRM connector with DPMS on. Assumes on when the kernel exposes nothing.
    var isScreenOn: Bool {
        let root = "/sys/class/drm"
        let connectors = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.contains("-") }
        var sawConnected = false
        for c in connectors {
            guard Self.read("\(root)/\(c)/status") == "connected" else { continue }
            sawConnected = true
            if Self.read("\(root)/\(c)/dpms") != "Off" { return true }
        }
        return !sawConnected
    }

    var isUnlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedUnlocked
    }

    private func refresh() {
        let locked = Self.sessionLocked()
        lock.lock()
        cachedUnlocked = !(locked ?? false)
        lock.unlock()
    }

    /// logind's LockedHint for our graphical session (GNOME and KDE both set it).
    private static func sessionLocked() -> Bool? {
        var session = ProcessInfo.processInfo.environment["XDG_SESSION_ID"]
        if session == nil || session!.isEmpty {
            // Running as a systemd user service: ask for the user's graphical session instead.
            session = run("/usr/bin/loginctl", ["show-user", String(getuid()), "-p", "Display", "--value"])
        }
        guard let session, !session.isEmpty,
              let hint = run("/usr/bin/loginctl", ["show-session", session, "-p", "LockedHint", "--value"])
        else { return nil }
        return hint == "yes"
    }

    private static func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Starts the daemon at login via an XDG autostart entry.
final class LinuxLoginItem: LoginItemManaging {
    private var url: URL {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
        return URL(fileURLWithPath: config).appendingPathComponent("autostart/spacetimecontinuum.desktop")
    }

    var isEnabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if isEnabled { try FileManager.default.removeItem(at: url) }
            return
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        let entry = """
            [Desktop Entry]
            Type=Application
            Name=Space Time Continuum
            Comment=Tracks keyboard and mouse time
            Exec="\(exe)" run
            X-GNOME-Autostart-enabled=true
            NoDisplay=true

            """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try entry.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Desktop notifications via `notify-send` (libnotify), which talks to org.freedesktop.Notifications.
final class LinuxNotifier: Notifying {
    func requestAuthorization() {}

    func notify(title: String, body: String) {
        if run("/usr/bin/notify-send", ["--app-name=Space Time Continuum", title, body]) == nil {
            print("Notification: \(title) — \(body)")
        }
    }
}

/// Runs a program and returns its trimmed stdout, or nil if it couldn't run or failed.
@discardableResult
func run(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
