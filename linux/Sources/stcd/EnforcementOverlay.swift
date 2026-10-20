import CGtk
import Foundation
import STCCore

/// Small always-on-top window with one countdown card per warning or lockout, like the Mac panel.
///
/// Sits at the top center of the primary monitor, above other windows, on every workspace. That
/// needs X11 (XWayland under Wayland; see `Gtk.initialize`). Never takes focus, so typing isn't
/// interrupted.
@MainActor
final class EnforcementOverlay {
    var onExtend: ((Int) -> Void)?

    private var window: UnsafeMutablePointer<GtkWidget>?
    private var cards: [Int: (title: UnsafeMutablePointer<GtkWidget>, clock: UnsafeMutablePointer<GtkWidget>, detail: UnsafeMutablePointer<GtkWidget>)] = [:]
    /// What the cards were built for; they're rebuilt when this changes.
    private var layout: [String] = []

    func show(_ enforcements: [Enforcement], safeWordEnabled: Bool, now: Date = Date()) {
        guard Gtk.isAvailable else { return }
        guard !enforcements.isEmpty else { hide(); return }
        let wanted = enforcements.map { "\($0.id):\($0.phase)" }
        if window == nil || wanted != layout { rebuild(enforcements, safeWordEnabled: safeWordEnabled) }
        for e in enforcements {
            guard let card = cards[e.id] else { continue }
            let locked = e.phase == .locked
            Gtk.setLabel(card.title, markup: "<b>\(Gtk.escape(locked ? "\(Self.deviceText(e)) blocked" : "\(Self.deviceText(e)) will be blocked"))</b>")
            Gtk.setLabel(card.clock, markup: "<span size='xx-large' font_family='monospace' weight='bold'>\(Self.clock(e.remaining(at: now)))</span>")
            let detail = locked
                ? (safeWordEnabled ? "until input is allowed again.\nType UNCLE to escape." : "until input is allowed again")
                : e.reason
            Gtk.setLabel(card.detail, markup: Gtk.escape(detail))
        }
    }

    func hide() {
        if let window { gtk_widget_destroy(window) }
        window = nil
        cards = [:]
        layout = []
    }

    private func rebuild(_ enforcements: [Enforcement], safeWordEnabled: Bool) {
        hide()
        let w = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        let win: UnsafeMutablePointer<GtkWindow> = Gtk.cast(w)
        gtk_window_set_title(win, "Space Time Continuum")
        gtk_window_set_decorated(win, 0)
        gtk_window_set_keep_above(win, 1)
        gtk_window_set_accept_focus(win, 0)
        gtk_window_set_focus_on_map(win, 0)
        gtk_window_set_skip_taskbar_hint(win, 1)
        gtk_window_set_skip_pager_hint(win, 1)
        gtk_window_set_resizable(win, 0)
        gtk_window_stick(win)
        gtk_window_set_type_hint(win, GDK_WINDOW_TYPE_HINT_UTILITY)
        // If something closes it anyway, forget it so the next update brings it back.
        Gtk.connect(w, "destroy") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window == w else { return }
                self.window = nil
                self.cards = [:]
                self.layout = []
            }
        }

        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_container_set_border_width(Gtk.cast(row), 8)
        for e in enforcements {
            let frame = gtk_frame_new(nil)!
            let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
            gtk_container_set_border_width(Gtk.cast(column), 16)
            gtk_widget_set_size_request(column, 268, -1)
            let title = Gtk.label(""), clock = Gtk.label(""), detail = Gtk.label("")
            for l in [title, clock, detail] { Gtk.add(column, l) }
            if e.phase == .warning {
                let id = e.id
                Gtk.add(column, Gtk.button("Just 5 more minutes") { [weak self] in
                    MainActor.assumeIsolated { self?.onExtend?(id) }
                })
            }
            Gtk.add(frame, column)
            Gtk.add(row, frame)
            cards[e.id] = (title, clock, detail)
        }
        Gtk.add(w, row)
        gtk_widget_show_all(w)
        placeAtTop(win)
        window = w
        layout = enforcements.map { "\($0.id):\($0.phase)" }
    }

    private func placeAtTop(_ win: UnsafeMutablePointer<GtkWindow>) {
        guard let display = gdk_display_get_default(),
              let monitor = gdk_display_get_primary_monitor(display) ?? gdk_display_get_monitor(display, 0)
        else { return }
        var area = GdkRectangle()
        gdk_monitor_get_workarea(monitor, &area)
        var width: Int32 = 0, height: Int32 = 0
        gtk_window_get_size(win, &width, &height)
        gtk_window_move(win, area.x + (area.width - width) / 2, area.y + 12)
    }

    static func deviceText(_ e: Enforcement) -> String {
        e.device == .keyboard ? "Keyboard" : "Mouse"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
