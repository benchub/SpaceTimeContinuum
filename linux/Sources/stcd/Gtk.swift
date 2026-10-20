import CGtk
import Foundation

/// Thin helpers over the GTK 3 C API. GTK's cast macros (GTK_WINDOW() etc.) don't import into
/// Swift, so pointers are re-typed with `cast`, and closures ride along as GObject user data.
enum Gtk {
    private(set) static var isAvailable = false

    /// Connects to the display. Returns false when there isn't one (e.g. over SSH).
    ///
    /// Prefers X11 (XWayland under a Wayland session): Wayland doesn't let apps place windows
    /// or keep them above others, which the Mistress Mode countdown needs. The tray icon and
    /// notifications go over D-Bus, so they don't care.
    static func initialize() -> Bool {
        gdk_set_allowed_backends("x11,*")
        stc_quiet_ayatana_deprecation()
        isAvailable = gtk_init_check(nil, nil) != 0
        return isAvailable
    }

    /// Opens a link in the default browser. Uses xdg-open with its output discarded, since
    /// browsers (and snapd starting a snap browser) write chatter to the terminal they inherit.
    static func openURL(_ url: String) {
        spawnDetached("/usr/bin/xdg-open", [url])
    }

    /// Runs the GTK main loop while still servicing the main dispatch queue (and so the main
    /// actor), which normally only `dispatchMain()` or a Foundation run loop would drain.
    static func main() -> Never {
        every(milliseconds: 10) { _ = RunLoop.main.run(mode: .default, before: Date()) }
        gtk_main()
        exit(0)
    }

    static func cast<T>(_ p: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<T> {
        p!.assumingMemoryBound(to: T.self)
    }

    static func cast<T, U>(_ p: UnsafeMutablePointer<U>?) -> UnsafeMutablePointer<T> {
        UnsafeMutableRawPointer(p!).assumingMemoryBound(to: T.self)
    }

    private final class Box {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    /// `g_signal_connect` for signals whose handler takes (instance, user_data).
    static func connect<T>(_ object: UnsafeMutablePointer<T>?, _ signal: String, _ action: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(action)).toOpaque()
        let handler: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in
            Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().action()
        }
        let release: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
            Unmanaged<Box>.fromOpaque(data!).release()
        }
        g_signal_connect_data(object, signal, unsafeBitCast(handler, to: GCallback.self), box, release, GConnectFlags(rawValue: 0))
    }

    /// Calls `action` when the desktop is about to show an AppIndicator menu.
    ///
    /// The menu is drawn by the desktop from a dbusmenu copy, so the GtkMenu is never shown.
    /// libdbusmenu-gtk keeps the root dbusmenu item on the GtkMenu under this key; it gets
    /// "about-to-show" (the AboutToShow call) and an "opened" event, depending on the desktop.
    static func onMenuOpening(_ menu: UnsafeMutablePointer<GtkWidget>, _ action: @escaping () -> Void) -> Bool {
        guard let root = g_object_get_data(UnsafeMutableRawPointer(menu).assumingMemoryBound(to: GObject.self),
                                           "dbusmenu-gtk-parser-cached-item") else { return false }
        let release: @convention(c) (gpointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
            Unmanaged<Box>.fromOpaque(data!).release()
        }
        // gboolean about_to_show(DbusmenuMenuitem *, gpointer)
        let aboutToShow: @convention(c) (gpointer?, gpointer?) -> gboolean = { _, data in
            Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().action()
            return 0
        }
        // gboolean event(DbusmenuMenuitem *, const gchar *name, GVariant *, guint timestamp, gpointer)
        let event: @convention(c) (gpointer?, UnsafePointer<CChar>?, gpointer?, UInt32, gpointer?) -> gboolean = { _, name, _, _, data in
            if let name, String(cString: name) == "opened" {
                Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().action()
            }
            return 0
        }
        g_signal_connect_data(root, "about-to-show", unsafeBitCast(aboutToShow, to: GCallback.self),
                              Unmanaged.passRetained(Box(action)).toOpaque(), release, GConnectFlags(rawValue: 0))
        g_signal_connect_data(root, "event", unsafeBitCast(event, to: GCallback.self),
                              Unmanaged.passRetained(Box(action)).toOpaque(), release, GConnectFlags(rawValue: 0))
        return true
    }

    /// Repeats `action` on the main thread until it's removed with `g_source_remove`.
    @discardableResult
    static func every(milliseconds: UInt32, _ action: @escaping () -> Void) -> UInt32 {
        let box = Unmanaged.passRetained(Box(action)).toOpaque()
        return g_timeout_add_full(G_PRIORITY_DEFAULT, milliseconds, { data in
            Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().action()
            return 1 // G_SOURCE_CONTINUE
        }, box, { data in Unmanaged<Box>.fromOpaque(data!).release() })
    }

    // MARK: Widgets

    static func label(_ text: String, markup: Bool = false) -> UnsafeMutablePointer<GtkWidget> {
        let l = gtk_label_new(nil)!
        if markup { gtk_label_set_markup(cast(l), text) } else { gtk_label_set_text(cast(l), text) }
        gtk_label_set_justify(cast(l), GTK_JUSTIFY_CENTER)
        gtk_label_set_line_wrap(cast(l), 1)
        return l
    }

    static func setLabel(_ l: UnsafeMutablePointer<GtkWidget>, markup: String) {
        gtk_label_set_markup(cast(l), markup)
    }

    static func button(_ title: String, _ action: @escaping () -> Void) -> UnsafeMutablePointer<GtkWidget> {
        let b = gtk_button_new_with_label(title)!
        connect(b, "clicked", action)
        return b
    }

    static func add(_ container: UnsafeMutablePointer<GtkWidget>, _ child: UnsafeMutablePointer<GtkWidget>) {
        gtk_container_add(cast(container), child)
    }

    static func escape(_ text: String) -> String {
        guard let escaped = g_markup_escape_text(text, -1) else { return text }
        defer { g_free(escaped) }
        return String(cString: escaped)
    }
}
