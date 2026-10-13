import XCTest
@testable import STCCore

class StoreTestCase: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 2
        return c
    }()

    func makeStore() throws -> ActivityStore {
        try ActivityStore(path: ":memory:", calendar: calendar)
    }

    func epoch(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Int64 {
        Int64(calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!.timeIntervalSince1970)
    }

    func activity(keys: Int = 10, pointer: Double = 1) -> Activity {
        Activity(screenOnSeconds: 60, unlockedSeconds: 60, attentiveSeconds: 60, keyActiveSeconds: keys,
                 keyPresses: keys * 2, keyDistanceMeters: Double(keys) * 0.002, pointerActiveSeconds: 20,
                 pointerDistanceMeters: pointer, anyActiveSeconds: 25)
    }

}

final class ActivityStoreTests: StoreTestCase {
    func testRecordUpdatesCachesAndTotals() throws {
        let store = try makeStore()
        let t = epoch(2026, 10, 13, 9, 0)
        try store.record(MinuteRollup(minuteStart: t, activity: activity()))
        try store.record(MinuteRollup(minuteStart: t + 60, activity: activity()))

        let totals = try store.totals()
        XCTAssertEqual(totals.activity.keyPresses, 40)
        XCTAssertEqual(totals.activity.pointerDistanceMeters, 2, accuracy: 1e-9)
        XCTAssertEqual(totals.trackingSince, t)

        let day = try store.dayActivity(localDate: "2026-10-13")
        XCTAssertEqual(day.anyActiveSeconds, 50)
        XCTAssertEqual(try store.minutes(from: t, to: t + 120).count, 2)
    }

    func testPartialMinuteMergeCapsSecondsAndDeltasCaches() throws {
        let store = try makeStore()
        let t = epoch(2026, 10, 13, 9, 0)
        var a = activity()
        a.screenOnSeconds = 40
        try store.record(MinuteRollup(minuteStart: t, activity: a))
        try store.markUploaded([t])
        try store.record(MinuteRollup(minuteStart: t, activity: a))
        let row = try store.minutes(from: t, to: t + 60).first!
        XCTAssertEqual(row.activity.screenOnSeconds, 60)
        XCTAssertNil(row.uploadedAt, "changed minute must be re-uploaded")
        XCTAssertEqual(try store.totals().activity.screenOnSeconds, 60)
        XCTAssertEqual(try store.dayActivity(localDate: "2026-10-13").screenOnSeconds, 60)
    }

    func testUploadBookkeeping() throws {
        let store = try makeStore()
        let t = epoch(2026, 10, 13, 9, 0)
        for i in 0..<5 { try store.record(MinuteRollup(minuteStart: t + Int64(i * 60), activity: activity())) }
        XCTAssertEqual(try store.unuploadedMinutes(limit: 3).map(\.minuteStart), [t, t + 60, t + 120])
        try store.markUploaded([t, t + 60])
        XCTAssertEqual(try store.unuploadedMinutes(limit: 10).count, 3)
    }

    func testResetAndSettings() throws {
        let store = try makeStore()
        var s = try store.loadSettings()
        XCTAssertEqual(s.deviceToken.count, 64)
        XCTAssertTrue(s.newEntropyEnabled)
        XCTAssertFalse(s.nannyEnabled)
        let oldGUID = s.deviceGUID
        s.leaderboardName = "SpaceCadet"
        s.regenerateIdentity()
        try store.saveSettings(s)
        let reloaded = try store.loadSettings()
        XCTAssertNotEqual(reloaded.deviceGUID, oldGUID)
        XCTAssertEqual(reloaded.leaderboardName, "")

        try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 13, 9), activity: activity()))
        try store.resetActivity()
        XCTAssertEqual(try store.totals(), LifetimeTotals())
        XCTAssertEqual(try store.dayActivity(localDate: "2026-10-13"), .zero)
    }

    func testPersistsAcrossReopen() throws {
        let path = NSTemporaryDirectory() + "stc-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try ActivityStore(path: path, calendar: calendar)
            try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 13, 9), activity: activity()))
        }
        let reopened = try ActivityStore(path: path, calendar: calendar)
        XCTAssertEqual(try reopened.totals().activity.keyPresses, 20)
    }
}

final class GraphBuilderTests: StoreTestCase {
    func testTodayBinsAndFutureNil() throws {
        let store = try makeStore()
        try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 13, 9, 7), activity: activity()))
        try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 13, 9, 20), activity: activity()))
        let g = GraphBuilder(store: store, calendar: calendar)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 10))!
        let s = try g.current(.today, now: now)
        XCTAssertEqual(s.bins.count, 96)
        XCTAssertEqual(s.bins[36].values?.keyActiveSeconds, 10) // 09:00–09:15
        XCTAssertEqual(s.bins[37].values?.keyActiveSeconds, 10) // 09:15–09:30
        XCTAssertEqual(s.bins[0].values?.keyActiveSeconds, 0)
        XCTAssertNil(s.bins[95].values)
    }

    func testWeekAndMonthBins() throws {
        let store = try makeStore()
        // Wednesday 2026-10-14 at 13:00 → week (Mon start) day 2, block 2.
        try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 14, 13), activity: activity()))
        let g = GraphBuilder(store: store, calendar: calendar)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let week = try g.current(.thisWeek, now: now)
        XCTAssertEqual(week.bins.count, 28)
        XCTAssertEqual(week.bins[2 * 4 + 2].values?.pointerDistanceMeters, 1)
        let month = try g.current(.thisMonth, now: now)
        XCTAssertEqual(month.bins.count, 31)
        XCTAssertEqual(month.bins[13].values?.pointerDistanceMeters, 1)
    }

    func testOverlays() throws {
        let store = try makeStore()
        // Two past weekdays (Mon 12th, Fri 9th) at 09:00, a Saturday (10th), and today (Tue 13th).
        try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 12, 9), activity: activity(keys: 10)))
        try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 9, 9), activity: activity(keys: 30)))
        try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 10, 9), activity: activity(keys: 50)))
        try store.record(MinuteRollup(minuteStart: epoch(2026, 10, 13, 9), activity: activity(keys: 5)))
        let g = GraphBuilder(store: store, calendar: calendar)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!

        let yesterday = try XCTUnwrap(g.overlay(.yesterday, period: .today, now: now))
        XCTAssertEqual(yesterday.bins[36].values?.keyActiveSeconds, 10)

        let weekday = try XCTUnwrap(g.overlay(.typicalWeekday, period: .today, now: now))
        XCTAssertEqual(weekday.bins[36].values?.keyActiveSeconds, 20) // (10 + 30) / 2, today excluded

        let weekend = try XCTUnwrap(g.overlay(.typicalWeekend, period: .today, now: now))
        XCTAssertEqual(weekend.bins[36].values?.keyActiveSeconds, 50)

        let typicalDay = try XCTUnwrap(g.overlay(.typicalPeriod, period: .today, now: now))
        XCTAssertEqual(typicalDay.bins[36].values?.keyActiveSeconds ?? 0, 30, accuracy: 1e-9)

        XCTAssertNil(try g.overlay(.lastWeek, period: .today, now: now))
        let lastWeek = try XCTUnwrap(g.overlay(.lastWeek, period: .thisWeek, now: now))
        XCTAssertEqual(lastWeek.bins[4 * 4 + 1].values?.keyActiveSeconds, 30) // Fri 9th, 06–12

        let monthWeekend = try XCTUnwrap(g.overlay(.typicalWeekend, period: .thisMonth, now: now))
        XCTAssertNil(monthWeekend.bins[8].values) // Fri 9th
        XCTAssertEqual(monthWeekend.bins[9].values?.keyActiveSeconds, 50) // Sat 10th
    }
}
