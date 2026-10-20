#if canImport(Glibc)
import Glibc
#endif
import Foundation
import STCCore

/// Screen-on and unlocked state. The recorder polls this every second, so the slow parts
/// (asking logind) are refreshed in the background every few seconds and cached.
final class LinuxSessionState: SessionStateProviding {
    private let lock = NSLock()
    private var cachedUnlocked = true
    private var timer: DispatchSourceTimer?

    init() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 5)
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
///
/// Uses posix_spawn rather than Foundation's Process: `Process.waitUntilExit()` spins the
/// current run loop and can hang forever when called from the main actor (async top-level code).
@discardableResult
func run(_ path: String, _ args: [String]) -> String? {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return nil }
    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addclose(&actions, fds[0])
    posix_spawn_file_actions_addclose(&actions, fds[1])

    let argv = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, path, &actions, nil, argv, environ)
    close(fds[1])
    guard spawned == 0 else {
        close(fds[0])
        return nil
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fds[0], &buffer, buffer.count)
        if n > 0 { data.append(buffer, count: n) } else if n < 0 && errno == EINTR { continue } else { break }
    }
    close(fds[0])

    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    // Exited normally (low 7 bits clear) with code 0.
    guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
