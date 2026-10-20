import CGtk
import Foundation

/// Thin helpers over the GTK 3 C API. GTK's cast macros (GTK_WINDOW() etc.) don't import into
/// Swift, so pointers are re-typed with `cast`, and closures ride along as GObject user data.
enum Gtk {
    private(set) static var isAvailable = false

    /// Connects to the display. Returns false when there isn't one (e.g. over SSH).
    static func initialize() -> Bool {
        isAvailable = gtk_init_check(nil, nil) != 0
        return isAvailable
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
