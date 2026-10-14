import Foundation

public enum GraphPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, thisWeek, thisMonth
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .today: "Today"
        case .thisWeek: "This week"
        case .thisMonth: "This month"
        }
    }
}

public enum GraphOverlay: String, CaseIterable, Identifiable, Sendable {
    case yesterday, lastWeek, lastMonth, typicalWeekday, typicalWeekend, typicalPeriod
    public var id: String { rawValue }

    public func title(for period: GraphPeriod) -> String {
        switch self {
        case .yesterday: "Yesterday"
        case .lastWeek: "Last week"
        case .lastMonth: "Last month"
        case .typicalWeekday: "Typical weekday"
        case .typicalWeekend: "Typical weekend"
        case .typicalPeriod:
            switch period {
            case .today: "Typical day"
            case .thisWeek: "Typical week"
            case .thisMonth: "Typical month"
            }
        }
    }

    /// Previous-period overlays only make sense for their matching period.
    public func isAvailable(for period: GraphPeriod) -> Bool {
        switch self {
        case .yesterday: period == .today
        case .lastWeek: period == .thisWeek
        case .lastMonth: period == .thisMonth
        case .typicalWeekday, .typicalWeekend, .typicalPeriod: true
        }
    }
}

/// Values plotted for one bin. Doubles because overlays are averages.
public struct BinValues: Equatable, Sendable {
    public var keyActiveSeconds: Double = 0
    public var pointerActiveSeconds: Double = 0
    public var anyActiveSeconds: Double = 0
    public var unlockedSeconds: Double = 0
    public var screenOnSeconds: Double = 0
    public var keyDistanceMeters: Double = 0
    public var pointerDistanceMeters: Double = 0

    public init() {}

    public init(_ a: Activity, dividedBy d: Double = 1) {
        keyActiveSeconds = Double(a.keyActiveSeconds) / d
        pointerActiveSeconds = Double(a.pointerActiveSeconds) / d
        anyActiveSeconds = Double(a.anyActiveSeconds) / d
        unlockedSeconds = Double(a.unlockedSeconds) / d
        screenOnSeconds = Double(a.screenOnSeconds) / d
        keyDistanceMeters = a.keyDistanceMeters / d
        pointerDistanceMeters = a.pointerDistanceMeters / d
    }
}

public struct GraphBin: Equatable, Sendable, Identifiable {
    public var index: Int
    public var start: Date
    public var end: Date
    /// nil = no value (future bins of the current series, or no history for an overlay).
    public var values: BinValues?
    public var id: Int { index }
}

public struct GraphSeries: Equatable, Sendable {
    public var period: GraphPeriod
    public var bins: [GraphBin]
}

/// Builds graph series from the quarter-hour and day caches.
public struct GraphBuilder {
    public let store: ActivityStore
    public var calendar: Calendar

    public init(store: ActivityStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    static let weekdaySet = [2, 3, 4, 5, 6]
    static let weekendSet = [1, 7]
    static let allDays = [1, 2, 3, 4, 5, 6, 7]

    // MARK: Layout

    struct Layout {
        var bins: [(start: Date, end: Date)]
        /// Local dates covered, in order (1 for today, 7 for week, N for month).
        var dates: [Date]
    }

    func layout(_ period: GraphPeriod, anchor: Date) -> Layout {
        let cal = calendar
        switch period {
        case .today:
            let day = cal.startOfDay(for: anchor)
            let bins = (0..<96).map { i in
                (cal.date(byAdding: .minute, value: i * 15, to: day)!, cal.date(byAdding: .minute, value: (i + 1) * 15, to: day)!)
            }
            return Layout(bins: bins, dates: [day])
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? cal.startOfDay(for: anchor)
            let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
            let bins = days.flatMap { d in
                (0..<4).map { b in (cal.date(byAdding: .hour, value: b * 6, to: d)!, cal.date(byAdding: .hour, value: (b + 1) * 6, to: d)!) }
            }
            return Layout(bins: bins, dates: days)
        case .thisMonth:
            let start = cal.dateInterval(of: .month, for: anchor)?.start ?? cal.startOfDay(for: anchor)
            let count = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
            let days = (0..<count).map { cal.date(byAdding: .day, value: $0, to: start)! }
            let bins = days.map { ($0, cal.date(byAdding: .day, value: 1, to: $0)!) }
            return Layout(bins: bins, dates: days)
        }
    }

    private func dateString(_ d: Date) -> String { LocalTime.dateString(d, calendar: calendar) }
    private func weekday(_ d: Date) -> Int { calendar.component(.weekday, from: d) }

    // MARK: Current

    /// The selected period containing `now`. Bins after `now` have nil values.
    public func current(_ period: GraphPeriod, now: Date = Date()) throws -> GraphSeries {
        let l = layout(period, anchor: now)
        let values = try actualValues(period, layout: l)
        let bins = l.bins.enumerated().map { i, b in
            GraphBin(index: i, start: b.start, end: b.end, values: b.start <= now ? values[i] : nil)
        }
        return GraphSeries(period: period, bins: bins)
    }

    /// Activity per bin for the period described by `layout`.
    private func actualValues(_ period: GraphPeriod, layout l: Layout) throws -> [BinValues] {
        var out = [Activity](repeating: .zero, count: l.bins.count)
        let dates = l.dates.map(dateString)
        store.lock.lock(); defer { store.lock.unlock() }
        switch period {
        case .today:
            try store.db.query("SELECT local_slot, \(ActivityStore.metricList) FROM quarters WHERE local_date = ?", [.text(dates[0])]) {
                (Int($0.int(0)), ActivityStore.activity(from: $0, offset: 1))
            }.forEach { slot, a in if out.indices.contains(slot) { out[slot] += a } }
        case .thisWeek:
            let index = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($1, $0) })
            try store.db.query(
                "SELECT local_date, local_slot, \(ActivityStore.metricList) FROM quarters WHERE local_date >= ? AND local_date <= ?",
                [.text(dates.first!), .text(dates.last!)]
            ) { ($0.text(0) ?? "", $0.int(1), ActivityStore.activity(from: $0, offset: 2)) }
                .forEach { date, slot, a in
                    guard let d = index[date] else { return }
                    let i = d * 4 + min(slot / 24, 3)
                    out[i] += a
                }
        case .thisMonth:
            let index = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($1, $0) })
            try store.db.query(
                "SELECT local_date, \(ActivityStore.metricList) FROM days WHERE local_date >= ? AND local_date <= ?",
                [.text(dates.first!), .text(dates.last!)]
            ) { ($0.text(0) ?? "", ActivityStore.activity(from: $0, offset: 1)) }
                .forEach { date, a in if let i = index[date] { out[i] += a } }
        }
        return out.map { BinValues($0) }
    }

    // MARK: Overlays

    /// Older data laid over the bins of the current period. nil if not applicable or no history.
    public func overlay(_ overlay: GraphOverlay, period: GraphPeriod, now: Date = Date()) throws -> GraphSeries? {
        guard overlay.isAvailable(for: period) else { return nil }
        let l = layout(period, anchor: now)
        let values: [BinValues?]
        switch overlay {
        case .yesterday, .lastWeek, .lastMonth:
            let component: Calendar.Component = period == .today ? .day : period == .thisWeek ? .weekOfYear : .month
            let anchor = calendar.date(byAdding: component, value: -1, to: now)!
            let prev = layout(period, anchor: anchor)
            let prevValues = try actualValues(period, layout: prev)
            values = l.bins.indices.map { $0 < prevValues.count ? prevValues[$0] : nil }
        case .typicalWeekday:
            values = try typical(period, layout: l, weekdays: Self.weekdaySet, now: now)
        case .typicalWeekend:
            values = try typical(period, layout: l, weekdays: Self.weekendSet, now: now)
        case .typicalPeriod:
            values = try typical(period, layout: l, weekdays: Self.allDays, now: now)
        }
        guard values.contains(where: { $0 != nil }) else { return nil }
        let bins = l.bins.enumerated().map { i, b in GraphBin(index: i, start: b.start, end: b.end, values: values[i]) }
        return GraphSeries(period: period, bins: bins)
    }

    private var sumList: String { ActivityStore.metricColumns.map { "SUM(\($0))" }.joined(separator: ", ") }

    /// Averages over complete past days (before today) whose weekday is in `weekdays`.
    private func typical(_ period: GraphPeriod, layout l: Layout, weekdays: [Int], now: Date) throws -> [BinValues?] {
        let today = dateString(now)
        let inList = weekdays.map(String.init).joined(separator: ",")
        store.lock.lock(); defer { store.lock.unlock() }

        // Number of past days with any data, per weekday.
        var dayCounts: [Int: Int] = [:]
        try store.db.query(
            "SELECT local_weekday, COUNT(*) FROM days WHERE local_date < ? AND local_weekday IN (\(inList)) GROUP BY local_weekday",
            [.text(today)]
        ) { ($0.int(0), $0.int(1)) }.forEach { dayCounts[$0] = $1 }
        let totalDays = dayCounts.values.reduce(0, +)
        guard totalDays > 0 else { return l.bins.map { _ in nil } }

        switch period {
        case .today:
            // Average quarter-hour profile across matching days.
            var sums = [Activity](repeating: .zero, count: 96)
            try store.db.query(
                "SELECT local_slot, \(sumList) FROM quarters WHERE local_date < ? AND local_weekday IN (\(inList)) GROUP BY local_slot",
                [.text(today)]
            ) { ($0.int(0), ActivityStore.activity(from: $0, offset: 1)) }
                .forEach { slot, a in if sums.indices.contains(slot) { sums[slot] = a } }
            return sums.map { BinValues($0, dividedBy: Double(totalDays)) }

        case .thisWeek:
            // Average 6-hour profile per weekday; days not in `weekdays` stay empty.
            var sums: [Int: [Activity]] = [:]
            try store.db.query(
                "SELECT local_weekday, local_slot / 24, \(sumList) FROM quarters WHERE local_date < ? AND local_weekday IN (\(inList)) GROUP BY 1, 2",
                [.text(today)]
            ) { ($0.int(0), $0.int(1), ActivityStore.activity(from: $0, offset: 2)) }
                .forEach { wd, block, a in
                    var arr = sums[wd] ?? [Activity](repeating: .zero, count: 4)
                    if arr.indices.contains(block) { arr[block] = a }
                    sums[wd] = arr
                }
            return l.dates.flatMap { d -> [BinValues?] in
                let wd = weekday(d)
                guard weekdays.contains(wd), let n = dayCounts[wd], n > 0 else { return [nil, nil, nil, nil] }
                let arr = sums[wd] ?? [Activity](repeating: .zero, count: 4)
                return arr.map { BinValues($0, dividedBy: Double(n)) }
            }

        case .thisMonth:
            if weekdays == Self.allDays {
                // Typical month: average per day-of-month.
                var byDom: [Int: (Activity, Int)] = [:]
                try store.db.query(
                    "SELECT CAST(substr(local_date, 9, 2) AS INTEGER), COUNT(*), \(sumList) FROM days WHERE local_date < ? GROUP BY 1",
                    [.text(today)]
                ) { ($0.int(0), $0.int(1), ActivityStore.activity(from: $0, offset: 2)) }
                    .forEach { byDom[$0] = ($2, $1) }
                return l.dates.map { d in
                    let dom = calendar.component(.day, from: d)
                    guard let (a, n) = byDom[dom], n > 0 else { return nil }
                    return BinValues(a, dividedBy: Double(n))
                }
            }
            // Typical weekday/weekend: average daily total, on matching dates only.
            let sum = try store.db.query(
                "SELECT \(sumList) FROM days WHERE local_date < ? AND local_weekday IN (\(inList))",
                [.text(today)]
            ) { ActivityStore.activity(from: $0) }.first ?? .zero
            let avg = BinValues(sum, dividedBy: Double(totalDays))
            return l.dates.map { weekdays.contains(weekday($0)) ? avg : nil }
        }
    }
}
