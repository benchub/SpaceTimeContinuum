import Charts
import STCCore
import SwiftUI

enum SeriesKind: String, CaseIterable, Identifiable {
    case keyboard = "Keyboard", pointer = "Mouse", unlocked = "Unlocked", screenOn = "Screen On"
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .keyboard: .blue
        case .pointer: .orange
        case .unlocked: .green
        case .screenOn: .purple
        }
    }

    var borderColor: Color {
        let c = NSColor(color).usingColorSpace(.deviceRGB) ?? .gray
        return Color(hue: c.hueComponent, saturation: min(1, c.saturationComponent * 1.4),
                     brightness: c.brightnessComponent * 0.75)
    }
}

private enum Metric {
    case time, distance

    var title: String { self == .time ? "Active time" : "Distance travelled" }
    var axisLabel: String { self == .time ? "Active minutes" : "Meters" }
    var kind: MeasureKind { self == .time ? .time : .space }

    /// Raw value in seconds or meters.
    /// nil when the series has no value for this metric (unlocked / screen-on are time only).
    func value(_ v: BinValues, _ kind: SeriesKind) -> Double? {
        switch (self, kind) {
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

    func real(_ raw: Double) -> String {
        self == .time ? RealUnits.duration(raw) : RealUnits.distance(raw)
    }
}

private struct Point: Identifiable {
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    var date: Date
    var value: Double
    var series: String
}

struct TimeGraphsView: View {
    @ObservedObject var model: AppModel

    @State private var period: GraphPeriod = .today
    @State private var shown: Set<SeriesKind> = [.keyboard, .pointer]
    @State private var pinned: GraphOverlay?
    @State private var hovered: GraphOverlay?
    @State private var current: GraphSeries?
    @State private var overlays: [GraphOverlay: GraphSeries] = [:]

    private var activeOverlay: GraphOverlay? { hovered ?? pinned }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Period", selection: $period) {
                    ForEach(GraphPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                Spacer()
                Text("Show:").foregroundStyle(.secondary)
                ForEach(SeriesKind.allCases) { kind in
                    Toggle(kind.rawValue, isOn: Binding(
                        get: { shown.contains(kind) },
                        set: { on in if on { shown.insert(kind) } else { shown.remove(kind) } }
                    ))
                    .toggleStyle(.button)
                    .tint(kind.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(kind.borderColor, lineWidth: 2)
                            .opacity(shown.contains(kind) ? 1 : 0)
                            .allowsHitTesting(false)
                    )
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    chart(.time)
                    chart(.distance)
                }
                overlayPicker
                    .frame(width: 170)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear(perform: reload)
        .onChange(of: period) { _, _ in
            if let p = pinned, !p.isAvailable(for: period) { pinned = nil }
            reload()
        }
        .onChange(of: model.dataVersion) { _, _ in reload() }
    }

    private func reload() {
        let builder = GraphBuilder(store: model.store)
        let now = Date()
        current = try? builder.current(period, now: now)
        var o: [GraphOverlay: GraphSeries] = [:]
        for overlay in GraphOverlay.allCases where overlay.isAvailable(for: period) {
            if let s = try? builder.overlay(overlay, period: period, now: now) { o[overlay] = s }
        }
        overlays = o
    }

    // MARK: Overlay picker

    private var overlayPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compare with").font(.headline)
            Text("Hover to preview, click to pin.").font(.caption).foregroundStyle(.secondary)
            ForEach(GraphOverlay.allCases) { overlay in
                let available = overlay.isAvailable(for: period)
                let hasData = overlays[overlay] != nil
                Button {
                    pinned = pinned == overlay ? nil : overlay
                } label: {
                    HStack {
                        Image(systemName: pinned == overlay ? "pin.fill" : "circle.dashed")
                            .frame(width: 16)
                        Text(overlay.title(for: period))
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(activeOverlay == overlay ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!available || !hasData)
                .opacity(available && hasData ? 1 : 0.4)
                .help(!available ? "Not available for \(period.title.lowercased())" : hasData ? "" : "Not enough history yet")
                .onHover { inside in
                    if inside, available, hasData { hovered = overlay } else if hovered == overlay { hovered = nil }
                }
            }
            Spacer()
        }
    }

    // MARK: Charts

    private func points(_ series: GraphSeries?, metric: Metric, suffix: String = "") -> [Point] {
        guard let series else { return [] }
        var out: [Point] = []
        for bin in series.bins {
            guard let v = bin.values else { continue }
            for kind in SeriesKind.allCases where shown.contains(kind) {
                guard let raw = metric.value(v, kind) else { continue }
                out.append(Point(date: bin.start, value: metric.plotted(raw), series: kind.rawValue + suffix))
            }
        }
        return out
    }

    private var domain: ClosedRange<Date> {
        guard let bins = current?.bins, let first = bins.first, let last = bins.last else { return Date()...Date() }
        return first.start...last.end
    }

    private func chart(_ metric: Metric) -> some View {
        let main = points(current, metric: metric)
        let overlaySeries = activeOverlay.flatMap { overlays[$0] }
        let overlayName = activeOverlay.map { " (\($0.title(for: period)))" } ?? ""
        let comparison = points(overlaySeries, metric: metric, suffix: overlayName)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.title).font(.headline)
                Spacer()
                Text(summary(metric)).font(.caption).foregroundStyle(.secondary)
            }
            GraphChart(
                metric: metric,
                main: main,
                comparison: comparison,
                domain: domain,
                period: period,
                current: current,
                overlay: overlaySeries,
                shown: shown,
                model: model
            )
            .frame(minHeight: 200)
        }
    }

    private func summary(_ metric: Metric) -> String {
        guard let bins = current?.bins else { return "" }
        let vals = bins.compactMap(\.values)
        return SeriesKind.allCases.compactMap { kind -> String? in
            guard shown.contains(kind), vals.first.flatMap({ metric.value($0, kind) }) != nil else { return nil }
            let total = vals.reduce(0) { $0 + (metric.value($1, kind) ?? 0) }
            return "\(kind.rawValue) \(metric.real(total))"
        }.joined(separator: " · ")
    }
}

private struct GraphChart: View {
    let metric: Metric
    let main: [Point]
    let comparison: [Point]
    let domain: ClosedRange<Date>
    let period: GraphPeriod
    let current: GraphSeries?
    let overlay: GraphSeries?
    let shown: Set<SeriesKind>
    let model: AppModel

    @State private var selection: Date?

    private func color(_ series: String) -> Color {
        SeriesKind.allCases.first { series.hasPrefix($0.rawValue) }?.color ?? .gray
    }

    private var selectedBin: GraphBin? {
        guard let selection, let bins = current?.bins else { return nil }
        return bins.first { $0.start <= selection && selection < $0.end }
    }

    var body: some View {
        Chart {
            ForEach(main) { p in
                AreaMark(x: .value("Time", p.date), y: .value(metric.axisLabel, p.value), series: .value("Series", p.series), stacking: .unstacked)
                    .foregroundStyle(color(p.series).opacity(0.18))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value(metric.axisLabel, p.value), series: .value("Series", p.series))
                    .foregroundStyle(color(p.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            ForEach(comparison) { p in
                LineMark(x: .value("Time", p.date), y: .value(metric.axisLabel, p.value), series: .value("Series", p.series))
                    .foregroundStyle(color(p.series).opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .interpolationMethod(.monotone)
            }
            if let bin = selectedBin {
                RuleMark(x: .value("Selected", bin.start))
                    .foregroundStyle(.gray.opacity(0.4))
                    .annotation(position: .top, alignment: .center, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(bin)
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartXSelection(value: $selection)
        .chartYAxisLabel(metric.axisLabel)
        .chartXAxis {
            switch period {
            case .today:
                AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                    AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.hour())
                }
            case .thisWeek:
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            case .thisMonth:
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.day())
                }
            }
        }
        .chartLegend(.hidden)
        .animation(.easeOut(duration: 0.2), value: comparison.count)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private func tooltip(_ bin: GraphBin) -> some View {
        let overlayBin = overlay?.bins.first { $0.index == bin.index }
        VStack(alignment: .leading, spacing: 3) {
            Text(rangeText(bin)).font(.caption.bold())
            if let v = bin.values {
                ForEach(Array(SeriesKind.allCases.enumerated()), id: \.offset) { i, kind in
                    if shown.contains(kind), let raw = metric.value(v, kind) { line(kind.rawValue, raw, salt: i + 1, bin: bin) }
                }
            } else {
                Text("The future is unwritten").font(.caption).foregroundStyle(.secondary)
            }
            if let ov = overlayBin?.values {
                Divider()
                ForEach(SeriesKind.allCases) { kind in
                    if shown.contains(kind), let raw = metric.value(ov, kind) {
                        Text("Compare \(kind.rawValue.lowercased()): \(metric.real(raw))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).shadow(radius: 2))
    }

    private func line(_ label: String, _ raw: Double, salt: Int, bin: GraphBin) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(label): \(metric.real(raw))").font(.caption)
            if raw > 0 {
                Text(model.stableSilly(raw, metric.kind, salt: salt &+ bin.index))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func rangeText(_ bin: GraphBin) -> String {
        switch period {
        case .today:
            return "\(bin.start.formatted(date: .omitted, time: .shortened)) – \(bin.end.formatted(date: .omitted, time: .shortened))"
        case .thisWeek:
            return "\(bin.start.formatted(.dateTime.weekday(.wide))) \(bin.start.formatted(date: .omitted, time: .shortened)) – \(bin.end.formatted(date: .omitted, time: .shortened))"
        case .thisMonth:
            return bin.start.formatted(date: .complete, time: .omitted)
        }
    }
}
