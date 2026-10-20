import CGtk
import Foundation
import STCCore

/// The top-bar icon and its menu (StatusNotifierItem via Ayatana AppIndicator). GNOME shows it
/// through the AppIndicator extension, which Ubuntu enables by default; KDE shows it natively.
///
/// Laid out like the Mac menu. The numbers are refreshed when the menu is about to open and
/// otherwise left alone, so nothing changes width while you're looking at it.
@MainActor
final class TrayIcon {
    private let daemon: Daemon
    private let indicator: UnsafeMutablePointer<AppIndicator>
    private let menu: UnsafeMutablePointer<GtkWidget>
    private var lines: [UnsafeMutablePointer<GtkWidget>] = []
    private var toggles: [(item: UnsafeMutablePointer<GtkWidget>, get: () -> Bool)] = []
    private var syncing = false
    private var lastOpened = Date.distantPast
    private lazy var leaderboardWindow = LeaderboardWindow(daemon: daemon)

    init(daemon: Daemon) {
        self.daemon = daemon
        indicator = stc_app_indicator_new("spacetimecontinuum", "input-keyboard", APP_INDICATOR_CATEGORY_APPLICATION_STATUS)!
        menu = gtk_menu_new()

        if let dir = Self.installIcon() {
            app_indicator_set_icon_theme_path(indicator, dir)
            app_indicator_set_icon_full(indicator, "spacetimecontinuum", "Space Time Continuum")
        }
        app_indicator_set_title(indicator, "Space Time Continuum")

        // Time Today (header, keyboard, its share, mouse, its share), then Distance since… (header, keys, pointer).
        for i in 0..<8 {
            let item = gtk_menu_item_new_with_label("")!
            // Headers look like section titles (dimmed); the numbers stay readable.
            if i == 0 || i == 5 { gtk_widget_set_sensitive(item, 0) }
            append(item)
            lines.append(item)
        }
        append(gtk_separator_menu_item_new())
        action("Leaderboard Settings…") { $0.leaderboardWindow.show() }
        action("Leaderboard") { _ in Gtk.openURL("https://spacetime.silentmedia.com/") }
        append(gtk_separator_menu_item_new())
        toggle("Nanny Mode", get: { $0.settings.nannyEnabled }, set: { $0.setNanny($1) })
        toggle("Mistress Mode", get: { $0.settings.mistressEnabled }, set: { $0.setMistress($1) })
        toggle("New Entropy", get: { $0.settings.newEntropyEnabled }, set: { $0.setNewEntropy($1) })
        toggle("Start at Login", get: { $0.settings.launchAtLogin }, set: { $0.setLaunchAtLogin($1) })
        append(gtk_separator_menu_item_new())
        action("Stop Recording & Quit") { $0.daemon.quit() }

        gtk_widget_show_all(menu)
        app_indicator_set_menu(indicator, Gtk.cast(menu))
        let hooked = Gtk.onMenuOpening(menu) { [weak self] in MainActor.assumeIsolated { self?.opening() } }
        if !hooked {
            // No way to tell when it opens; refresh once a minute instead.
            Gtk.every(milliseconds: 60_000) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        }
        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
        refresh()
    }

    /// Desktops may announce one opening twice (AboutToShow, then "opened"); a second re-roll
    /// would change the text while the menu is up.
    private func opening() {
        guard Date().timeIntervalSince(lastOpened) > 2 else { return }
        lastOpened = Date()
        refresh()
    }

    /// Re-reads the numbers (re-rolling the silly units) and the checkmarks.
    func refresh() {
        let snap = daemon.menuSnapshot()
        let today = snap.today, lifetime = snap.lifetime.activity
        func share(_ active: Int) -> String {
            let pct = today.screenOnSeconds > 0 ? Int((Double(min(active, today.screenOnSeconds)) / Double(today.screenOnSeconds) * 100).rounded()) : 0
            return "      (\(pct)% of the time your computer screen was on)"
        }
        let since = snap.lifetime.trackingSince.map {
            "Distance since " + Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .abbreviated, time: .omitted)
        } ?? "Distance travelled"
        let texts = [
            "Time Today",
            "⌨️  Keyboard: \(daemon.formatter.format(Double(today.keyActiveSeconds), .time))",
            share(today.keyActiveSeconds),
            "🖱️  Mouse: \(daemon.formatter.format(Double(today.pointerActiveSeconds), .time))",
            share(today.pointerActiveSeconds),
            since,
            "⌨️  Keys: \(daemon.formatter.format(lifetime.keyDistanceMeters, .space))",
            "🖱️  Pointer: \(daemon.formatter.format(lifetime.pointerDistanceMeters, .space))",
        ]
        for (item, text) in zip(lines, texts) { gtk_menu_item_set_label(Gtk.cast(item), text) }
        refreshToggles()
    }

    /// Updates just the checkmarks (after a setting changes elsewhere).
    func refreshToggles() {
        syncing = true
        for t in toggles { gtk_check_menu_item_set_active(Gtk.cast(t.item), t.get() ? 1 : 0) }
        syncing = false
    }

    private func append(_ item: UnsafeMutablePointer<GtkWidget>?) {
        gtk_menu_shell_append(Gtk.cast(menu), item)
    }

    private func action(_ title: String, _ run: @escaping (TrayIcon) -> Void) {
        let item = gtk_menu_item_new_with_label(title)!
        Gtk.connect(item, "activate") { [weak self] in
            MainActor.assumeIsolated { if let self { run(self) } }
        }
        append(item)
    }

    private func toggle(_ title: String, get: @escaping (Daemon) -> Bool, set: @escaping (Daemon, Bool) -> Void) {
        let item = gtk_check_menu_item_new_with_label(title)!
        Gtk.connect(item, "toggled") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.syncing else { return }
                set(self.daemon, gtk_check_menu_item_get_active(Gtk.cast(item)) != 0)
                self.refreshToggles()
            }
        }
        append(item)
        toggles.append((item, { [unowned daemon] in get(daemon) }))
    }

    /// Icon themes only load PNG/SVG, so convert the shared JPEG once into the cache directory.
    private static func installIcon() -> String? {
        let env = ProcessInfo.processInfo.environment
        let cache = env["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let dir = cache.appendingPathComponent("SpaceTimeContinuum/icons")
        let png = dir.appendingPathComponent("spacetimecontinuum.png")
        if FileManager.default.fileExists(atPath: png.path) { return dir.path }
        guard let jpg = Resources.url("icon", "jpg") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let pixbuf = gdk_pixbuf_new_from_file_at_scale(jpg.path, 64, 64, 1, nil) else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
        return gdk_pixbuf_savev(pixbuf, png.path, "png", nil, nil, nil) != 0 ? dir.path : nil
    }
}
