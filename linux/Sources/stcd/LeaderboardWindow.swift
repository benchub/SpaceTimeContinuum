import CGtk
import Foundation
import STCCore

/// Leaderboard name and opt-in, like the Leaderboard section of the Mac Configuration window.
@MainActor
final class LeaderboardWindow {
    private let daemon: Daemon
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var entry: UnsafeMutablePointer<GtkWidget>!
    private var setButton: UnsafeMutablePointer<GtkWidget>!
    private var join: UnsafeMutablePointer<GtkWidget>!
    private var status: UnsafeMutablePointer<GtkWidget>!
    private var footer: UnsafeMutablePointer<GtkWidget>!
    private var syncing = false
    private var claimMessage: (text: String, success: Bool)?

    private static let explanation = "If you join the leaderboard, your time and distance data will be sent to a server along with your username and IP address, which very roughly and possibly incorrectly puts you on a map. You also get to see yourself on the leaderboard. Requires you to give yourself a leaderboard name."

    init(daemon: Daemon) {
        self.daemon = daemon
    }

    func show() {
        if let window {
            gtk_window_present(Gtk.cast(window))
            return
        }
        let w = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(Gtk.cast(w), "Space Time Continuum — Leaderboard")
        gtk_window_set_default_size(Gtk.cast(w), 460, -1)
        gtk_window_set_position(Gtk.cast(w), GTK_WIN_POS_CENTER)
        gtk_window_set_resizable(Gtk.cast(w), 0)
        Gtk.connect(w, "destroy") { [weak self] in
            MainActor.assumeIsolated {
                self?.window = nil
                self?.daemon.onNameStateChange = nil
            }
        }

        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        gtk_container_set_border_width(Gtk.cast(column), 18)

        let about = Gtk.label(Self.explanation)
        gtk_label_set_xalign(Gtk.cast(about), 0)
        gtk_label_set_justify(Gtk.cast(about), GTK_JUSTIFY_LEFT)
        gtk_label_set_max_width_chars(Gtk.cast(about), 60)
        Gtk.add(column, about)

        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        entry = gtk_entry_new()
        gtk_entry_set_placeholder_text(Gtk.cast(entry), "Enter a name here to join")
        gtk_entry_set_max_length(Gtk.cast(entry), Int32(LeaderboardName.maxLength))
        gtk_entry_set_text(Gtk.cast(entry), daemon.settings.leaderboardName)
        gtk_box_pack_start(Gtk.cast(row), entry, 1, 1, 0)
        Gtk.connect(entry, "changed") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.claimMessage = nil
                self.daemon.leaderboardNameEdited(self.text)
                self.update()
            }
        }
        Gtk.connect(entry, "activate") { [weak self] in MainActor.assumeIsolated { self?.claim() } }
        setButton = Gtk.button("Set name") { [weak self] in MainActor.assumeIsolated { self?.claim() } }
        Gtk.add(row, setButton)
        Gtk.add(column, row)

        status = Gtk.label("")
        gtk_label_set_xalign(Gtk.cast(status), 0)
        Gtk.add(column, status)

        join = gtk_check_button_new_with_label("Join the leaderboard")
        Gtk.connect(join, "toggled") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.syncing else { return }
                self.daemon.setLeaderboardEnabled(gtk_toggle_button_get_active(Gtk.cast(self.join)) != 0)
                self.update()
            }
        }
        Gtk.add(column, join)

        footer = Gtk.label("")
        gtk_label_set_xalign(Gtk.cast(footer), 0)
        Gtk.add(column, footer)

        Gtk.add(w, column)
        window = w
        daemon.onNameStateChange = { [weak self] in self?.update() }
        update()
        gtk_widget_show_all(w)
        gtk_window_present(Gtk.cast(w))
    }

    private var text: String {
        String(cString: gtk_entry_get_text(Gtk.cast(entry)))
    }

    private func claim() {
        guard daemon.nameState == .available, LeaderboardName.normalize(text) != daemon.settings.leaderboardName else { return }
        gtk_widget_set_sensitive(setButton, 0)
        daemon.claimLeaderboardName(text) { [weak self] message in
            self?.claimMessage = message
            self?.update()
        }
    }

    private func update() {
        guard window != nil else { return }
        let available = Features.leaderboardAvailable
        let saved = daemon.settings.leaderboardName
        let current = LeaderboardName.normalize(text)

        syncing = true
        gtk_toggle_button_set_active(Gtk.cast(join), daemon.settings.leaderboardEnabled ? 1 : 0)
        syncing = false
        gtk_widget_set_sensitive(join, available && !saved.isEmpty ? 1 : 0)
        gtk_widget_set_sensitive(entry, available ? 1 : 0)
        gtk_widget_set_sensitive(setButton, available && daemon.nameState == .available && current != saved ? 1 : 0)

        let (message, color): (String, String?) = {
            if let m = claimMessage { return (m.text, m.success ? "green" : "red") }
            if !saved.isEmpty, current == saved { return ("You can always change your name.", nil) }
            switch daemon.nameState {
            case .idle: return ("", nil)
            case .checking: return ("Checking…", "gray")
            case .available: return ("Available", "green")
            case .unavailable(let reason): return (reason == "reserved" ? "Unavailable (reserved)" : "Unavailable", "red")
            case .invalid: return ("3–50 letters, digits, spaces, _ - or . (start and end with a letter or digit)", "red")
            case .error(let e): return (e, "orange")
            }
        }()
        let escaped = Gtk.escape(message)
        Gtk.setLabel(status, markup: "<small>\(color.map { "<span foreground='\($0)'>\(escaped)</span>" } ?? escaped)</small>")

        let hint = !available ? "The leaderboard is coming in a future version."
            : saved.isEmpty ? "To join, enter a name, click “Set name”, then turn on the checkbox." : ""
        Gtk.setLabel(footer, markup: "<small><span foreground='gray'>\(Gtk.escape(hint))</span></small>")
    }
}
