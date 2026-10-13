import Foundation

/// Persists minute rollups plus pre-aggregated quarter-hour, day and lifetime totals.
///
/// Every `record` call updates all four in one transaction so that startup only needs
/// to read the `totals` row and graphs only need the small cache tables.
public final class ActivityStore: @unchecked Sendable {
    let db: SQLiteDatabase
    let lock = NSRecursiveLock()
    public var calendar: Calendar

    static let metricColumns = [
        "screen_on_s", "unlocked_s", "attentive_s", "key_active_s", "key_presses",
        "key_distance_m", "pointer_active_s", "pointer_distance_m", "any_active_s",
    ]
    static let metricList = metricColumns.joined(separator: ", ")
    private static let metricDefs = metricColumns.map {
        $0.hasSuffix("_m") ? "\($0) REAL NOT NULL DEFAULT 0" : "\($0) INTEGER NOT NULL DEFAULT 0"
    }.joined(separator: ",\n  ")
    private static let metricPlaceholders = Array(repeating: "?", count: metricColumns.count).joined(separator: ", ")
    private static let addExcluded = metricColumns.map { "\($0) = \($0) + excluded.\($0)" }.joined(separator: ", ")

    /// - Parameter path: file path, or ":memory:" for tests.
    public init(path: String, calendar: Calendar = .current) throws {
        self.db = try SQLiteDatabase(path: path)
        self.calendar = calendar
        try migrate()
    }

    private func migrate() throws {
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        let version = try db.query("SELECT MAX(version) FROM schema_version") { $0.isNull(0) ? 0 : $0.int(0) }.first ?? 0
        if version < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE minutes (
                  minute_start INTEGER PRIMARY KEY,
                  \(Self.metricDefs),
                  uploaded_at INTEGER
                );
                CREATE INDEX minutes_unuploaded ON minutes(minute_start) WHERE uploaded_at IS NULL;
                CREATE TABLE quarters (
                  quarter_start INTEGER PRIMARY KEY,
                  local_date TEXT NOT NULL,
                  local_weekday INTEGER NOT NULL,
                  local_slot INTEGER NOT NULL,
                  \(Self.metricDefs)
                );
                CREATE INDEX quarters_date ON quarters(local_date);
                CREATE INDEX quarters_weekday_slot ON quarters(local_weekday, local_slot);
                CREATE TABLE days (
                  local_date TEXT PRIMARY KEY,
                  local_weekday INTEGER NOT NULL,
                  \(Self.metricDefs)
                );
                CREATE TABLE totals (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  tracking_since INTEGER,
                  \(Self.metricDefs)
                );
                CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO schema_version (version) VALUES (1);
                """)
            }
        }
    }

    // MARK: - Writing

    /// Records a (possibly partial) minute. If the minute already exists, the two are merged.
    public func record(_ rollup: MinuteRollup) throws {
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            let existing = try db.query(
                "SELECT \(Self.metricList), uploaded_at FROM minutes WHERE minute_start = ?",
                [.int(rollup.minuteStart)]
            ) { (Self.activity(from: $0), $0.optionalInt64(9)) }.first

            let base = existing?.0 ?? .zero
            let merged = base.mergedWithinMinute(rollup.activity)
            let delta = merged - base
            let uploadedAt = (existing != nil && delta == .zero) ? existing?.1 : nil

            try db.run(
                "INSERT OR REPLACE INTO minutes (minute_start, \(Self.metricList), uploaded_at) VALUES (?, \(Self.metricPlaceholders), ?)",
                [.int(rollup.minuteStart)] + Self.values(merged) + [.optionalInt(uploadedAt)]
            )
            guard delta != .zero || existing == nil else { return }

            let local = LocalTime(epoch: rollup.minuteStart, calendar: calendar)
            let quarterStart = rollup.minuteStart - ((rollup.minuteStart % 900) + 900) % 900
            try db.run(
                """
                INSERT INTO quarters (quarter_start, local_date, local_weekday, local_slot, \(Self.metricList))
                VALUES (?, ?, ?, ?, \(Self.metricPlaceholders))
                ON CONFLICT(quarter_start) DO UPDATE SET \(Self.addExcluded)
                """,
                [.int(quarterStart), .text(local.date), .int(local.weekday), .int(local.slot)] + Self.values(delta)
            )
            try db.run(
                """
                INSERT INTO days (local_date, local_weekday, \(Self.metricList))
                VALUES (?, ?, \(Self.metricPlaceholders))
                ON CONFLICT(local_date) DO UPDATE SET \(Self.addExcluded)
                """,
                [.text(local.date), .int(local.weekday)] + Self.values(delta)
            )
            try db.run(
                """
                INSERT INTO totals (id, tracking_since, \(Self.metricList))
                VALUES (1, ?, \(Self.metricPlaceholders))
                ON CONFLICT(id) DO UPDATE SET \(Self.addExcluded),
                  tracking_since = MIN(COALESCE(tracking_since, excluded.tracking_since), excluded.tracking_since)
                """,
                [.int(rollup.minuteStart)] + Self.values(delta)
            )
        }
    }

    /// Deletes all activity data. Settings are kept.
    public func resetActivity() throws {
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            try db.execute("DELETE FROM minutes; DELETE FROM quarters; DELETE FROM days; DELETE FROM totals;")
        }
    }

    // MARK: - Reading

    public func totals() throws -> LifetimeTotals {
        lock.lock(); defer { lock.unlock() }
        return try db.query("SELECT \(Self.metricList), tracking_since FROM totals WHERE id = 1") {
            LifetimeTotals(activity: Self.activity(from: $0), trackingSince: $0.optionalInt64(9))
        }.first ?? LifetimeTotals()
    }

    /// Activity for the local calendar day containing `date`.
    public func dayActivity(containing date: Date) throws -> Activity {
        let local = LocalTime(epoch: Int64(date.timeIntervalSince1970), calendar: calendar)
        return try dayActivity(localDate: local.date)
    }

    public func dayActivity(localDate: String) throws -> Activity {
        lock.lock(); defer { lock.unlock() }
        return try db.query("SELECT \(Self.metricList) FROM days WHERE local_date = ?", [.text(localDate)]) {
            Self.activity(from: $0)
        }.first ?? .zero
    }

    /// Minute rows with `from <= minute_start < to`, ascending.
    public func minutes(from: Int64, to: Int64) throws -> [MinuteRollup] {
        lock.lock(); defer { lock.unlock() }
        return try db.query(
            "SELECT \(Self.metricList), uploaded_at, minute_start FROM minutes WHERE minute_start >= ? AND minute_start < ? ORDER BY minute_start",
            [.int(from), .int(to)]
        ) { MinuteRollup(minuteStart: $0.int64(10), activity: Self.activity(from: $0), uploadedAt: $0.optionalInt64(9)) }
    }

    public func unuploadedMinutes(limit: Int) throws -> [MinuteRollup] {
        lock.lock(); defer { lock.unlock() }
        return try db.query(
            "SELECT \(Self.metricList), uploaded_at, minute_start FROM minutes WHERE uploaded_at IS NULL ORDER BY minute_start LIMIT ?",
            [.int(limit)]
        ) { MinuteRollup(minuteStart: $0.int64(10), activity: Self.activity(from: $0), uploadedAt: nil) }
    }

    public func markUploaded(_ minuteStarts: [Int64], at time: Date = Date()) throws {
        guard !minuteStarts.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            let stmt = try db.prepare("UPDATE minutes SET uploaded_at = ? WHERE minute_start = ?")
            for start in minuteStarts {
                try stmt.bind([.int(Int64(time.timeIntervalSince1970)), .int(start)])
                while try stmt.step() {}
            }
        }
    }

    // MARK: - Settings

    public func setting(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.text(0) }.first ?? nil
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        if let value {
            try db.run("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }

    // MARK: - Helpers

    /// Reads the 9 metric columns starting at column `offset`.
    static func activity(from s: Statement, offset: Int32 = 0) -> Activity {
        Activity(
            screenOnSeconds: s.int(offset + 0),
            unlockedSeconds: s.int(offset + 1),
            attentiveSeconds: s.int(offset + 2),
            keyActiveSeconds: s.int(offset + 3),
            keyPresses: s.int(offset + 4),
            keyDistanceMeters: s.double(offset + 5),
            pointerActiveSeconds: s.int(offset + 6),
            pointerDistanceMeters: s.double(offset + 7),
            anyActiveSeconds: s.int(offset + 8)
        )
    }

    static func values(_ a: Activity) -> [SQLValue] {
        [
            .int(a.screenOnSeconds), .int(a.unlockedSeconds), .int(a.attentiveSeconds),
            .int(a.keyActiveSeconds), .int(a.keyPresses), .double(a.keyDistanceMeters),
            .int(a.pointerActiveSeconds), .double(a.pointerDistanceMeters), .int(a.anyActiveSeconds),
        ]
    }
}

/// Local calendar position of an instant, as stored in the cache tables.
public struct LocalTime: Equatable, Sendable {
    /// "yyyy-MM-dd" in the calendar's time zone.
    public let date: String
    /// 1 = Sunday ... 7 = Saturday.
    public let weekday: Int
    /// Quarter-hour of the (wall clock) day, 0...95.
    public let slot: Int

    public init(epoch: Int64, calendar: Calendar) {
        let d = Date(timeIntervalSince1970: TimeInterval(epoch))
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: d)
        date = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        weekday = c.weekday ?? 1
        slot = (c.hour ?? 0) * 4 + (c.minute ?? 0) / 15
    }

    public static func dateString(_ date: Date, calendar: Calendar) -> String {
        LocalTime(epoch: Int64(date.timeIntervalSince1970), calendar: calendar).date
    }
}
