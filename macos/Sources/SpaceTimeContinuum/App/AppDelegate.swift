import AppKit
import STCCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var windows: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            model = try AppModel()
        } catch {
            NSLog("Space Time Continuum failed to start: \(error)")
            let alert = NSAlert()
            alert.messageText = "Space Time Continuum couldn't start"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🍵"
            button.setAccessibilityLabel("Space Time Continuum")
            button.toolTip = "Space Time Continuum"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        model.start()
        if model.isFirstRun { showConfiguration() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Menu

    /// Rebuilt every time the menu opens, so silly units get re-rolled each time.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snap = model.snapshot()

        if !model.hasInputPermission {
            menu.addItem(item("⚠️ Grant Input Monitoring permission…", action: #selector(openPermissions)))
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: "Time Today"))
        menu.addItem(info(
            "⌨️  Keyboard: \(model.silly(Double(snap.today.keyActiveSeconds), .time))",
            tip: "\(RealUnits.duration(Double(snap.today.keyActiveSeconds))) of typing, \(snap.today.keyPresses) key presses"
        ))
        menu.addItem(screenOnLine(active: snap.today.keyActiveSeconds, screenOn: snap.today.screenOnSeconds))
        menu.addItem(info(
            "🖱️  Mouse: \(model.silly(Double(snap.today.pointerActiveSeconds), .time))",
            tip: "\(RealUnits.duration(Double(snap.today.pointerActiveSeconds))) of pointer movement"
        ))
        menu.addItem(screenOnLine(active: snap.today.pointerActiveSeconds, screenOn: snap.today.screenOnSeconds))

        let since = snap.lifetime.trackingSince.map {
            "Distance since " + Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .omitted)
        } ?? "Distance travelled"
        menu.addItem(.sectionHeader(title: since))
        menu.addItem(info(
            "⌨️  Keys: \(model.silly(snap.lifetime.activity.keyDistanceMeters, .space))",
            tip: "\(RealUnits.distance(snap.lifetime.activity.keyDistanceMeters)) over \(snap.lifetime.activity.keyPresses) key presses"
        ))
        menu.addItem(info(
            "🖱️  Pointer: \(model.silly(snap.lifetime.activity.pointerDistanceMeters, .space))",
            tip: RealUnits.distance(snap.lifetime.activity.pointerDistanceMeters)
        ))

        menu.addItem(.separator())
        menu.addItem(item("Time Graphs…", action: #selector(showGraphs)))
        menu.addItem(item("Configuration…", action: #selector(showConfiguration)))
        menu.addItem(item("Leaderboard", action: #selector(openLeaderboard)))
        menu.addItem(.separator())
        menu.addItem(item("Stop Recording & Quit", action: #selector(quit)))
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    /// Informational line: a plain view, so it's unselectable but keeps normal text color.
    private func info(_ title: String, tip: String? = nil, small: Bool = false, indent: CGFloat = 0) -> NSMenuItem {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: small ? 11 : 0)
        label.textColor = .labelColor
        label.sizeToFit()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 36 + indent, height: label.frame.height + 4))
        label.frame.origin = NSPoint(x: 14 + indent, y: 2)
        container.addSubview(label)
        container.toolTip = tip
        let i = NSMenuItem()
        i.view = container
        return i
    }

    /// Secondary line showing active time as a share of screen-on time.
    private func screenOnLine(active: Int, screenOn: Int) -> NSMenuItem {
        let pct = screenOn > 0 ? Int((Double(min(active, screenOn)) / Double(screenOn) * 100).rounded()) : 0
        return info("(\(pct)% of the time your computer screen was on)", small: true, indent: 22)
    }

    // MARK: Actions

    @objc private func openLeaderboard() {
        if let url = URL(string: "https://spacetime.silentmedia.com/") { NSWorkspace.shared.open(url) }
    }

    @objc private func openPermissions() {
        model.requestInputPermission()
        model.openInputMonitoringSettings()
    }

    @objc func showConfiguration() {
        show(id: "config", title: "Space Time Continuum — Configuration", size: NSSize(width: 560, height: 720)) {
            ConfigurationView(model: self.model) { [weak self] in self?.windows["config"]?.close() }
        }
    }

    @objc private func showGraphs() {
        show(id: "graphs", title: "Space Time Continuum — Time Graphs", size: NSSize(width: 980, height: 680)) {
            TimeGraphsView(model: self.model)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func show<V: View>(id: String, title: String, size: NSSize, content: () -> V) {
        if let w = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("STC-\(id)")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if id == "config" { self?.model.finishConfiguration() }
                self?.windows[id] = nil
            }
        }
        windows[id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
