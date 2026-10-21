import CGtk
import Foundation
import STCCore

/// Converts a number of seconds or meters into silly units, like the Mac Conversion Tool.
@MainActor
final class ConversionWindow {
    private let daemon: Daemon
    private var window: UnsafeMutablePointer<GtkWidget>?

    init(daemon: Daemon) {
        self.daemon = daemon
    }

    func show() {
        if let window {
            gtk_window_present(Gtk.cast(window))
            return
        }
        let w = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(Gtk.cast(w), "Space Time Continuum — Conversion Tool")
        gtk_window_set_default_size(Gtk.cast(w), 480, 240)
        gtk_window_set_position(Gtk.cast(w), GTK_WIN_POS_CENTER)
        Gtk.connect(w, "destroy") { [weak self] in MainActor.assumeIsolated { self?.window = nil } }

        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 20)!
        gtk_container_set_border_width(Gtk.cast(column), 20)
        let time = row(column, title: "Time (seconds)", kind: .time)
        _ = row(column, title: "Distance (meters)", kind: .space)

        Gtk.add(w, column)
        window = w
        gtk_widget_show_all(w)
        gtk_widget_grab_focus(time)
        gtk_window_present(Gtk.cast(w))
    }

    /// A title, an entry with a Convert button, and the result underneath. Returns the entry.
    private func row(_ column: UnsafeMutablePointer<GtkWidget>, title: String, kind: MeasureKind) -> UnsafeMutablePointer<GtkWidget> {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        let heading = Gtk.label("<b>\(Gtk.escape(title))</b>", markup: true)
        gtk_label_set_xalign(Gtk.cast(heading), 0)
        Gtk.add(box, heading)

        let line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(Gtk.cast(entry), "0")
        gtk_box_pack_start(Gtk.cast(line), entry, 1, 1, 0)
        let result = Gtk.label(" ")
        gtk_label_set_xalign(Gtk.cast(result), 0)
        gtk_label_set_justify(Gtk.cast(result), GTK_JUSTIFY_LEFT)
        gtk_style_context_add_class(gtk_widget_get_style_context(result), "dim-label")

        let convert = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                gtk_label_set_text(Gtk.cast(result), self.convert(String(cString: gtk_entry_get_text(Gtk.cast(entry))), kind))
            }
        }
        Gtk.connect(entry, "changed") {
            let text = String(cString: gtk_entry_get_text(Gtk.cast(entry)))
            let clean = Self.sanitize(text)
            // Setting the text fires "changed" again, which then finds nothing to fix.
            guard clean != text else { return }
            // Defer: replacing the text mid-insert leaves the cursor in the wrong place.
            DispatchQueue.main.async {
                gtk_entry_set_text(Gtk.cast(entry), clean)
                gtk_editable_set_position(OpaquePointer(entry), -1)
            }
        }
        Gtk.connect(entry, "activate", convert)
        Gtk.add(line, Gtk.button("Convert", convert))
        Gtk.add(box, line)
        Gtk.add(box, result)
        Gtk.add(column, box)
        return entry
    }

    /// Digits and at most one period; a leading period gets a 0 in front.
    nonisolated static func sanitize(_ input: String) -> String {
        var out = ""
        var seenPeriod = false
        for ch in input {
            if ch.isASCII, ch.isNumber {
                out.append(ch)
            } else if ch == ".", !seenPeriod {
                seenPeriod = true
                if out.isEmpty { out = "0" }
                out.append(ch)
            }
        }
        return out
    }

    private func convert(_ input: String, _ kind: MeasureKind) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return "Enter a non-negative number." }
        return daemon.formatter.format(value, kind)
    }
}
