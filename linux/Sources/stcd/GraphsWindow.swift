import CGtk
import Foundation
import STCCore

/// Time and distance graphs for today, this week or this month, with an optional comparison
/// overlay, like the Mac Time Graphs window. Drawn with cairo.
@MainActor
final class GraphsWindow {
    private enum Series: CaseIterable {
        case keyboard, pointer, unlocked, screenOn

        var title: String {
            switch self {
            case .keyboard: "Keyboard"
            case .pointer: "Mouse"
            case .unlocked: "Unlocked"
            case .screenOn: "Screen On"
            }
        }

        var rgb: (Double, Double, Double) {
            switch self {
            case .keyboard: (0.0, 0.48, 1.0)
            case .pointer: (1.0, 0.58, 0.0)
            case .unlocked: (0.2, 0.78, 0.35)
            case .screenOn: (0.69, 0.32, 0.87)
            }
        }

        var hex: String {
            let (r, g, b) = rgb
            return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
        }
    }

    private enum Metric: CaseIterable {
        case time, distance

        var title: String { self == .time ? "Active time" : "Distance travelled" }
        var axisLabel: String { self == .time ? "Active minutes" : "Meters" }
        var kind: MeasureKind { self == .time ? .time : .space }

        /// Raw value in seconds or meters. nil when the series has no value for this metric
        /// (unlocked and screen-on are time only).
        func value(_ v: BinValues, _ series: Series) -> Double? {
            switch (self, series) {
            case (.time, .keyboard): v.keyActiveSeconds
            case (.time, .pointer): v.pointerActiveSeconds
            case (.time, .unlocked): v.unlockedSeconds
            case (.time, .screenOn): v.screenOnSeconds
            case (.distance, .keyboard): v.keyDistanceMeters
            case (.distance, .pointer): v.pointerDistanceMeters
            default: nil
            }
        }

        /// Value as plotted (minutes for time).
        func plotted(_ raw: Double) -> Double { self == .time ? raw / 60 : raw }

        func real(_ raw: Double) -> String { self == .time ? RealUnits.duration(raw) : RealUnits.distance(raw) }
    }

    private struct Chart {
        var area: UnsafeMutablePointer<GtkWidget>
        var summary: UnsafeMutablePointer<GtkWidget>
        /// Pointer position over the chart, for the tooltip.
        var hoverX: Double?
    }

    private let daemon: Daemon
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var period: GraphPeriod = .today
    private var shown: Set<Series> = [.keyboard, .pointer]
    private var pinned: GraphOverlay?
    private var hovered: GraphOverlay?
    private var current: GraphSeries?
    private var overlays: [GraphOverlay: GraphSeries] = [:]
    private var charts: [Metric: Chart] = [:]
    private var periodButtons: [(GraphPeriod, UnsafeMutablePointer<GtkWidget>)] = []
    private var overlayButtons: [(GraphOverlay, UnsafeMutablePointer<GtkWidget>)] = []
    private var syncing = false

    private var activeOverlay: GraphOverlay? { hovered ?? pinned }

    init(daemon: Daemon) {
        self.daemon = daemon
    }

    func show() {
        if let window {
            gtk_window_present(Gtk.cast(window))
            return
        }
        let w = gtk_window_new(GTK_WINDOW_TOPLEVEL)!
        gtk_window_set_title(Gtk.cast(w), "Space Time Continuum — Time Graphs")
        gtk_window_set_default_size(Gtk.cast(w), 980, 680)
        gtk_window_set_position(Gtk.cast(w), GTK_WIN_POS_CENTER)
        Gtk.connect(w, "destroy") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window = nil
                self.charts = [:]
                self.periodButtons = []
                self.overlayButtons = []
                self.hovered = nil
                self.daemon.onDataChanged = nil
            }
        }

        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        gtk_container_set_border_width(Gtk.cast(column), 16)
        Gtk.add(column, toolbar())

        let body = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16)!
        let chartsColumn = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16)!
        gtk_widget_set_size_request(chartsColumn, 620, -1)
        for metric in Metric.allCases {
            gtk_box_pack_start(Gtk.cast(chartsColumn), chart(metric), 1, 1, 0)
        }
        gtk_box_pack_start(Gtk.cast(body), chartsColumn, 1, 1, 0)
        let picker = overlayPicker()
        gtk_widget_set_size_request(picker, 170, -1)
        gtk_box_pack_start(Gtk.cast(body), picker, 0, 0, 0)
        gtk_box_pack_start(Gtk.cast(column), body, 1, 1, 0)

        Gtk.add(w, column)
        window = w
        daemon.onDataChanged = { [weak self] in self?.reload() }
        reload()
        gtk_widget_show_all(w)
        gtk_window_present(Gtk.cast(w))
    }

    // MARK: Layout

    /// Period buttons on the left, series toggles on the right.
    private func toolbar() -> UnsafeMutablePointer<GtkWidget> {
        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let periods = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_style_context_add_class(gtk_widget_get_style_context(periods), "linked")
        for p in GraphPeriod.allCases {
            let b = gtk_toggle_button_new_with_label(p.title)!
            Gtk.connect(b, "toggled") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.syncing else { return }
                    self.select(p)
                }
            }
            Gtk.add(periods, b)
            periodButtons.append((p, b))
        }
        Gtk.add(bar, periods)

        let show = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let label = Gtk.label("Show:")
        gtk_style_context_add_class(gtk_widget_get_style_context(label), "dim-label")
        Gtk.add(show, label)
        for s in Series.allCases {
            let b = gtk_check_button_new()!
            let l = Gtk.label("<span foreground='\(s.hex)'>●</span> \(s.title)", markup: true)
            Gtk.add(b, l)
            gtk_toggle_button_set_active(Gtk.cast(b), shown.contains(s) ? 1 : 0)
            Gtk.connect(b, "toggled") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if gtk_toggle_button_get_active(Gtk.cast(b)) != 0 { self.shown.insert(s) } else { self.shown.remove(s) }
                    self.redraw()
                }
            }
            Gtk.add(show, b)
        }
        gtk_box_pack_end(Gtk.cast(bar), show, 0, 0, 0)
        return bar
    }

    private func chart(_ metric: Metric) -> UnsafeMutablePointer<GtkWidget> {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
        let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        Gtk.add(header, Gtk.label("<b>\(metric.title)</b>", markup: true))
        let summary = Gtk.label("")
        gtk_style_context_add_class(gtk_widget_get_style_context(summary), "dim-label")
        gtk_box_pack_end(Gtk.cast(header), summary, 0, 0, 0)
        Gtk.add(box, header)

        let area = gtk_drawing_area_new()!
        gtk_widget_set_size_request(area, -1, 200)
        gtk_widget_add_events(area, Int32(GDK_POINTER_MOTION_MASK.rawValue | GDK_LEAVE_NOTIFY_MASK.rawValue))
        Gtk.connectEvent(area, "draw") { [weak self] cr in
            MainActor.assumeIsolated {
                if let self, let cr { self.draw(metric, OpaquePointer(cr)) }
            }
            return true
        }
        Gtk.connectEvent(area, "motion-notify-event") { [weak self] event in
            let x = event!.assumingMemoryBound(to: GdkEventMotion.self).pointee.x
            MainActor.assumeIsolated { self?.hover(metric, x) }
            return false
        }
        Gtk.connectEvent(area, "leave-notify-event") { [weak self] _ in
            MainActor.assumeIsolated { self?.hover(metric, nil) }
            return false
        }
        gtk_box_pack_start(Gtk.cast(box), area, 1, 1, 0)
        charts[metric] = Chart(area: area, summary: summary)
        return box
    }

    /// "Compare with" buttons: hover to preview, click to pin.
    private func overlayPicker() -> UnsafeMutablePointer<GtkWidget> {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        let title = Gtk.label("<b>Compare with</b>", markup: true)
        gtk_label_set_xalign(Gtk.cast(title), 0)
        Gtk.add(box, title)
        let hint = Gtk.label("<small>Hover to preview, click to pin.</small>", markup: true)
        gtk_label_set_xalign(Gtk.cast(hint), 0)
        gtk_style_context_add_class(gtk_widget_get_style_context(hint), "dim-label")
        Gtk.add(box, hint)
        for overlay in GraphOverlay.allCases {
            let b = gtk_toggle_button_new_with_label("")!
            gtk_button_set_relief(Gtk.cast(b), GTK_RELIEF_NONE)
            if let child = gtk_bin_get_child(Gtk.cast(b)) { gtk_label_set_xalign(Gtk.cast(child), 0) }
            Gtk.connect(b, "toggled") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.syncing else { return }
                    self.pinned = gtk_toggle_button_get_active(Gtk.cast(b)) != 0 ? overlay : nil
                    self.syncButtons()
                    self.redraw()
                }
            }
            Gtk.connectEvent(b, "enter-notify-event") { [weak self] _ in
                MainActor.assumeIsolated { self?.preview(overlay) }
                return false
            }
            Gtk.connectEvent(b, "leave-notify-event") { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hovered == overlay else { return }
                    self.preview(nil)
                }
                return false
            }
            Gtk.add(box, b)
            overlayButtons.append((overlay, b))
        }
        return box
    }

    // MARK: State

    private func select(_ p: GraphPeriod) {
        period = p
        if let o = pinned, !o.isAvailable(for: p) { pinned = nil }
        hovered = nil
        reload()
    }

    private func preview(_ overlay: GraphOverlay?) {
        if let overlay, !(overlay.isAvailable(for: period) && overlays[overlay] != nil) { return }
        hovered = overlay
        redraw()
    }

    private func reload() {
        guard window != nil else { return }
        let builder = GraphBuilder(store: daemon.store)
        let now = Date()
        current = try? builder.current(period, now: now)
        var o: [GraphOverlay: GraphSeries] = [:]
        for overlay in GraphOverlay.allCases where overlay.isAvailable(for: period) {
            if let s = try? builder.overlay(overlay, period: period, now: now) { o[overlay] = s }
        }
        overlays = o
        syncButtons()
        redraw()
    }

    private func syncButtons() {
        syncing = true
        for (p, b) in periodButtons { gtk_toggle_button_set_active(Gtk.cast(b), p == period ? 1 : 0) }
        for (overlay, b) in overlayButtons {
            let available = overlay.isAvailable(for: period), hasData = overlays[overlay] != nil
            gtk_button_set_label(Gtk.cast(b), overlay.title(for: period))
            if let child = gtk_bin_get_child(Gtk.cast(b)) { gtk_label_set_xalign(Gtk.cast(child), 0) }
            gtk_toggle_button_set_active(Gtk.cast(b), pinned == overlay ? 1 : 0)
            gtk_widget_set_sensitive(b, available && hasData ? 1 : 0)
            let tip = !available ? "Not available for \(period.title.lowercased())" : hasData ? nil : "Not enough history yet"
            gtk_widget_set_tooltip_text(b, tip)
        }
        syncing = false
    }

    private func redraw() {
        for (metric, chart) in charts {
            Gtk.setLabel(chart.summary, markup: "<small>\(Gtk.escape(summary(metric)))</small>")
            gtk_widget_queue_draw(chart.area)
        }
    }

    private func hover(_ metric: Metric, _ x: Double?) {
        guard charts[metric] != nil else { return }
        charts[metric]!.hoverX = x
        gtk_widget_queue_draw(charts[metric]!.area)
    }

    private func summary(_ metric: Metric) -> String {
        guard let bins = current?.bins else { return "" }
        let vals = bins.compactMap(\.values)
        return Series.allCases.compactMap { s -> String? in
            guard shown.contains(s), vals.first.flatMap({ metric.value($0, s) }) != nil else { return nil }
            let total = vals.reduce(0) { $0 + (metric.value($1, s) ?? 0) }
            return "\(s.title) \(metric.real(total))"
        }.joined(separator: " · ")
    }

    // MARK: Drawing

    private struct Plot {
        var x0, y0, width, height: Double
        var start, end: Date
        var maxY: Double

        func x(_ d: Date) -> Double {
            x0 + width * d.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))
        }

        func y(_ v: Double) -> Double { y0 + height - height * min(v, maxY) / maxY }
    }

    private func draw(_ metric: Metric, _ cr: OpaquePointer) {
        guard let chart = charts[metric], let bins = current?.bins, let first = bins.first, let last = bins.last else { return }
        let width = Double(gtk_widget_get_allocated_width(chart.area))
        let height = Double(gtk_widget_get_allocated_height(chart.area))
        var fg = GdkRGBA()
        gtk_style_context_get_color(gtk_widget_get_style_context(chart.area), GTK_STATE_FLAG_NORMAL, &fg)
        let dark = (fg.red + fg.green + fg.blue) / 3 > 0.5

        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, 11)

        // Card background.
        roundedRect(cr, 0, 0, width, height, 10)
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.05)
        cairo_fill(cr)

        let overlaySeries = activeOverlay.flatMap { overlays[$0] }
        let main = lines(current, metric)
        let comparison = lines(overlaySeries, metric)
        let peak = (main + comparison).flatMap { $0.points.map(\.1) }.max() ?? 0
        let step = Self.niceStep(max(peak, metric == .time ? 1 : 0.01) / 4)
        let maxY = step * max(1, (peak / step).rounded(.up))

        let left = 14 + textWidth(cr, Self.number(maxY, step: step)) + 8
        let plot = Plot(x0: left, y0: 24, width: width - left - 14, height: height - 24 - 30,
                        start: first.start, end: last.end, maxY: maxY)

        // Axis title, gridlines and labels.
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.6)
        text(cr, metric.axisLabel, x: 10, y: 15)
        var v = 0.0
        while v <= maxY + step / 2 {
            let y = plot.y(v)
            cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.12)
            cairo_set_line_width(cr, 1)
            cairo_move_to(cr, plot.x0, y.rounded() + 0.5)
            cairo_line_to(cr, plot.x0 + plot.width, y.rounded() + 0.5)
            cairo_stroke(cr)
            cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.6)
            let label = Self.number(v, step: step)
            text(cr, label, x: plot.x0 - 6 - textWidth(cr, label), y: y + 4)
            v += step
        }
        for (date, label) in xTicks(bins) {
            let x = plot.x(date)
            cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.12)
            cairo_move_to(cr, x.rounded() + 0.5, plot.y0)
            cairo_line_to(cr, x.rounded() + 0.5, plot.y0 + plot.height)
            cairo_stroke(cr)
            cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.6)
            text(cr, label, x: x + 3, y: plot.y0 + plot.height + 16)
        }

        // Current period: filled area under a solid line.
        for line in main where line.points.count > 0 {
            let (r, g, b) = line.series.rgb
            path(cr, line.points, plot)
            cairo_line_to(cr, plot.x(line.points.last!.0), plot.y(0))
            cairo_line_to(cr, plot.x(line.points.first!.0), plot.y(0))
            cairo_close_path(cr)
            cairo_set_source_rgba(cr, r, g, b, 0.18)
            cairo_fill(cr)
            path(cr, line.points, plot)
            cairo_set_source_rgba(cr, r, g, b, 1)
            cairo_set_line_width(cr, 2)
            cairo_stroke(cr)
        }
        // Comparison: dashed.
        var dash: [Double] = [5, 4]
        for line in comparison where line.points.count > 0 {
            let (r, g, b) = line.series.rgb
            path(cr, line.points, plot)
            cairo_set_source_rgba(cr, r, g, b, 0.7)
            cairo_set_line_width(cr, 1.5)
            cairo_set_dash(cr, &dash, 2, 0)
            cairo_stroke(cr)
            cairo_set_dash(cr, nil, 0, 0)
        }

        // Hovered bin: a rule and a tooltip.
        guard let hx = chart.hoverX, hx >= plot.x0, hx <= plot.x0 + plot.width,
              let bin = bins.first(where: { plot.x($0.start) <= hx && hx < plot.x($0.end) }) ?? (hx >= plot.x(last.start) ? last : nil)
        else { return }
        let rx = plot.x(bin.start).rounded() + 0.5
        cairo_set_source_rgba(cr, 0.5, 0.5, 0.5, 0.5)
        cairo_set_line_width(cr, 1)
        cairo_move_to(cr, rx, plot.y0)
        cairo_line_to(cr, rx, plot.y0 + plot.height)
        cairo_stroke(cr)
        tooltip(cr, metric, bin, overlay: overlaySeries, at: rx, plot: plot, dark: dark, fg: fg)
    }

    private struct Line {
        var series: Series
        var points: [(Date, Double)]
    }

    private func lines(_ series: GraphSeries?, _ metric: Metric) -> [Line] {
        guard let series else { return [] }
        return Series.allCases.filter { shown.contains($0) }.compactMap { s in
            let points = series.bins.compactMap { bin -> (Date, Double)? in
                guard let v = bin.values, let raw = metric.value(v, s) else { return nil }
                return (bin.start, metric.plotted(raw))
            }
            return points.isEmpty ? nil : Line(series: s, points: points)
        }
    }

    private func path(_ cr: OpaquePointer, _ points: [(Date, Double)], _ plot: Plot) {
        cairo_new_path(cr)
        for (i, p) in points.enumerated() {
            if i == 0 { cairo_move_to(cr, plot.x(p.0), plot.y(p.1)) } else { cairo_line_to(cr, plot.x(p.0), plot.y(p.1)) }
        }
    }

    private func xTicks(_ bins: [GraphBin]) -> [(Date, String)] {
        let f = DateFormatter()
        switch period {
        case .today:
            f.setLocalizedDateFormatFromTemplate("j")
            return bins.filter { $0.index % 12 == 0 }.map { ($0.start, f.string(from: $0.start)) }
        case .thisWeek:
            f.setLocalizedDateFormatFromTemplate("EEE")
            return bins.filter { $0.index % 4 == 0 }.map { ($0.start, f.string(from: $0.start)) }
        case .thisMonth:
            f.setLocalizedDateFormatFromTemplate("d")
            return bins.filter { $0.index % 5 == 0 }.map { ($0.start, f.string(from: $0.start)) }
        }
    }

    private func rangeText(_ bin: GraphBin) -> String {
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        switch period {
        case .today:
            return "\(time.string(from: bin.start)) – \(time.string(from: bin.end))"
        case .thisWeek:
            let day = DateFormatter()
            day.setLocalizedDateFormatFromTemplate("EEEE")
            return "\(day.string(from: bin.start)) \(time.string(from: bin.start)) – \(time.string(from: bin.end))"
        case .thisMonth:
            let day = DateFormatter()
            day.dateStyle = .full
            day.timeStyle = .none
            return day.string(from: bin.start)
        }
    }

    private func tooltip(_ cr: OpaquePointer, _ metric: Metric, _ bin: GraphBin, overlay: GraphSeries?,
                         at x: Double, plot: Plot, dark: Bool, fg: GdkRGBA) {
        // (text, size, alpha)
        var rows: [(String, Double, Double)] = [(rangeText(bin), 11.5, 1)]
        if let v = bin.values {
            for (i, s) in Series.allCases.enumerated() where shown.contains(s) {
                guard let raw = metric.value(v, s) else { continue }
                rows.append(("\(s.title): \(metric.real(raw))", 11, 1))
                if raw > 0 { rows.append((daemon.stableSilly(raw, metric.kind, salt: (i + 1) &+ bin.index), 10, 0.65)) }
            }
        } else {
            rows.append(("The future is unwritten", 11, 0.65))
        }
        if let ov = overlay?.bins.first(where: { $0.index == bin.index })?.values {
            for s in Series.allCases where shown.contains(s) {
                if let raw = metric.value(ov, s) { rows.append(("Compare \(s.title.lowercased()): \(metric.real(raw))", 10, 0.65)) }
            }
        }

        let lineHeight = 15.0, pad = 8.0
        var width = 0.0
        for (t, size, _) in rows {
            cairo_set_font_size(cr, size)
            width = max(width, textWidth(cr, t))
        }
        width += pad * 2
        let height = Double(rows.count) * lineHeight + pad * 2 - 3
        let onLeft = x < plot.x0 + plot.width / 2
        let left = onLeft ? x + 6 : x - 6 - width
        let top = plot.y0 + 4

        roundedRect(cr, left, top, width, height, 8)
        if dark { cairo_set_source_rgba(cr, 0.17, 0.17, 0.18, 0.96) } else { cairo_set_source_rgba(cr, 1, 1, 1, 0.96) }
        cairo_fill_preserve(cr)
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.2)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)

        for (i, (t, size, alpha)) in rows.enumerated() {
            cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, i == 0 ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL)
            cairo_set_font_size(cr, size)
            cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, alpha)
            text(cr, t, x: left + pad, y: top + pad + 9 + Double(i) * lineHeight)
        }
    }

    private func roundedRect(_ cr: OpaquePointer, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + w - r, y + r, r, -.pi / 2, 0)
        cairo_arc(cr, x + w - r, y + h - r, r, 0, .pi / 2)
        cairo_arc(cr, x + r, y + h - r, r, .pi / 2, .pi)
        cairo_arc(cr, x + r, y + r, r, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
    }

    private func text(_ cr: OpaquePointer, _ s: String, x: Double, y: Double) {
        cairo_move_to(cr, x, y)
        cairo_show_text(cr, s)
    }

    private func textWidth(_ cr: OpaquePointer, _ s: String) -> Double {
        var extents = cairo_text_extents_t()
        cairo_text_extents(cr, s, &extents)
        return extents.x_advance
    }

    /// 1, 2 or 5 times a power of ten, at least `raw`.
    private static func niceStep(_ raw: Double) -> Double {
        let magnitude = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 5, 10] where m * magnitude >= raw { return m * magnitude }
        return 10 * magnitude
    }

    private static func number(_ v: Double, step: Double) -> String {
        let decimals = step >= 1 ? 0 : Int(-floor(log10(step)))
        return String(format: "%.\(decimals)f", v)
    }
}
