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
            button.image = NSImage(systemSymbolName: "infinity.circle", accessibilityDescription: "Space Time Continuum")
            button.image?.isTemplate = true
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

        menu.addItem(.sectionHeader(title: "Today"))
        menu.addItem(info(
            "⌨️  Keyboard: \(model.silly(Double(snap.today.keyActiveSeconds), .time))",
            tip: "\(RealUnits.duration(Double(snap.today.keyActiveSeconds))) of typing, \(snap.today.keyPresses) key presses"
        ))
        menu.addItem(info(
            "🖱️  Mouse: \(model.silly(Double(snap.today.pointerActiveSeconds), .time))",
            tip: "\(RealUnits.duration(Double(snap.today.pointerActiveSeconds))) of pointer movement"
        ))

        let since = snap.lifetime.trackingSince.map {
            "Since " + Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .omitted)
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
        menu.addItem(item("Time Graphs…", action: #selector(showGraphs), key: "g"))
        menu.addItem(item("Configuration…", action: #selector(showConfiguration), key: ","))
        let leaderboard = NSMenuItem(title: "Leaderboard", action: nil, keyEquivalent: "")
        leaderboard.isEnabled = false
        leaderboard.toolTip = "Coming in a future version"
        menu.addItem(leaderboard)
        menu.addItem(.separator())
        menu.addItem(item("Stop Recording & Quit", action: #selector(quit), key: "q"))
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    /// Informational line: enabled so it isn't greyed out, but does nothing.
    private func info(_ title: String, tip: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = true
        i.toolTip = tip
        return i
    }

    // MARK: Actions

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
