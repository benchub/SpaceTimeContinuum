import CGtk
import Foundation
import STCCore

/// The top-bar icon and its menu (StatusNotifierItem via Ayatana AppIndicator). GNOME shows it
/// through the AppIndicator extension, which Ubuntu enables by default; KDE shows it natively.
@MainActor
final class TrayIcon {
    private let daemon: Daemon
    private let indicator: UnsafeMutablePointer<AppIndicator>
    private let menu: UnsafeMutablePointer<GtkWidget>
    private var infoItems: [UnsafeMutablePointer<GtkWidget>] = []
    private var toggles: [(item: UnsafeMutablePointer<GtkWidget>, get: () -> Bool)] = []
    private var syncing = false

    init(daemon: Daemon) {
        self.daemon = daemon
        indicator = app_indicator_new("spacetimecontinuum", "input-keyboard", APP_INDICATOR_CATEGORY_APPLICATION_STATUS)!
        menu = gtk_menu_new()

        if let dir = Self.installIcon() {
            app_indicator_set_icon_theme_path(indicator, dir)
            app_indicator_set_icon_full(indicator, "spacetimecontinuum", "Space Time Continuum")
        }
        app_indicator_set_title(indicator, "Space Time Continuum")

        for _ in 0..<4 {
            let item = gtk_menu_item_new_with_label("")!
            gtk_widget_set_sensitive(item, 0)
            append(item)
            infoItems.append(item)
        }
        append(gtk_separator_menu_item_new())
        toggle("Nanny Mode", get: { $0.settings.nannyEnabled }, set: { $0.setNanny($1) })
        toggle("Mistress Mode", get: { $0.settings.mistressEnabled }, set: { $0.setMistress($1) })
        toggle("New Entropy", get: { $0.settings.newEntropyEnabled }, set: { $0.setNewEntropy($1) })
        toggle("Leaderboard", get: { $0.settings.leaderboardEnabled }, set: { $0.setLeaderboardEnabled($1) })
        toggle("Start at login", get: { $0.settings.launchAtLogin }, set: { $0.setLaunchAtLogin($1) })
        append(gtk_separator_menu_item_new())
        let quit = gtk_menu_item_new_with_label("Quit")!
        Gtk.connect(quit, "activate") { [weak daemon] in
            MainActor.assumeIsolated { if let daemon { daemon.quit() } }
        }
        append(quit)

        gtk_widget_show_all(menu)
        app_indicator_set_menu(indicator, Gtk.cast(menu))
        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE)
        refresh()
    }

    /// Updates the numbers and checkmarks. Called every few seconds and after settings change.
    func refresh() {
        let lines = daemon.menuLines()
        for (item, text) in zip(infoItems, lines + Array(repeating: "", count: max(0, infoItems.count - lines.count))) {
            gtk_menu_item_set_label(Gtk.cast(item), text)
            gtk_widget_set_visible(item, text.isEmpty ? 0 : 1)
        }
        syncing = true
        for t in toggles { gtk_check_menu_item_set_active(Gtk.cast(t.item), t.get() ? 1 : 0) }
        syncing = false
    }

    private func append(_ item: UnsafeMutablePointer<GtkWidget>?) {
        gtk_menu_shell_append(Gtk.cast(menu), item)
    }

    private func toggle(_ title: String, get: @escaping (Daemon) -> Bool, set: @escaping (Daemon, Bool) -> Void) {
        let item = gtk_check_menu_item_new_with_label(title)!
        Gtk.connect(item, "toggled") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.syncing else { return }
                set(self.daemon, gtk_check_menu_item_get_active(Gtk.cast(item)) != 0)
                self.refresh()
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
