import XCTest
@testable import STCCore

final class NannyRulesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_760_007_210)

    func rows(_ minutes: Int, active: Bool, attentive: Int) -> [MinuteRollup] {
        let nowMinute = Int64(now.timeIntervalSince1970) / 60 * 60
        return (1...minutes).map { i in
            MinuteRollup(minuteStart: nowMinute - Int64(i * 60), activity: Activity(
                screenOnSeconds: attentive, unlockedSeconds: attentive, attentiveSeconds: attentive,
                keyActiveSeconds: active ? 5 : 0, anyActiveSeconds: active ? 5 : 0))
        }
    }

    func testDefaultRulesMatchOriginalBehaviour() {
        let n = Nanny(rules: NannyRules())
        XCTAssertEqual(n.activeWindowMinutes, 60)
        XCTAssertEqual(n.activeMinutesThreshold, 48)
        XCTAssertEqual(n.sessionWindowMinutes, 120)
    }

    func testCustomThresholds() {
        var rules = NannyRules()
        rules.activityPercent = 50
        rules.activityWindowHours = 2
        rules.screenOnBreakEnabled = false
        let n = Nanny(rules: rules)
        XCTAssertEqual(n.activeMinutesThreshold, 60)
        XCTAssertEqual(n.historyMinutes, 120)
        let recent = rows(120, active: true, attentive: 60)
        XCTAssertEqual(n.evaluate(recent: recent, now: now, lastNagAt: nil), .busyHour(activeMinutes: 120, windowMinutes: 120))
    }

    func testRulesCanBeDisabledSeparately() {
        var rules = NannyRules()
        rules.activityBreakEnabled = false
        rules.screenOnBreakEnabled = false
        let recent = rows(120, active: true, attentive: 60)
        XCTAssertNil(Nanny(rules: rules).evaluate(recent: recent, now: now, lastNagAt: nil))
        rules.screenOnBreakEnabled = true
        rules.screenOnHours = 3
        XCTAssertNil(Nanny(rules: rules).evaluate(recent: recent, now: now, lastNagAt: nil))
        rules.screenOnHours = 1
        XCTAssertEqual(Nanny(rules: rules).evaluate(recent: recent, now: now, lastNagAt: nil), .longSession(minutes: 60))
    }

    func testStretchTracker() {
        var t = StretchTracker()
        var m: Int64 = 0
        func add(_ s: Int, after gap: Int64 = 60) -> Bool { m += gap; return t.add(minuteStart: m, attentiveSeconds: s, everyMinutes: 20) }
        for _ in 0..<19 { XCTAssertFalse(add(60)) }
        XCTAssertTrue(add(60))
        XCTAssertFalse(add(60))

        // A locked minute (screen may still be on, but nothing attentive) starts over.
        for _ in 0..<18 { XCTAssertFalse(add(60)) }
        XCTAssertFalse(add(0))
        for _ in 0..<19 { XCTAssertFalse(add(60)) }
        XCTAssertTrue(add(60))

        // So does a gap in minutes, e.g. the Mac slept.
        for _ in 0..<18 { XCTAssertFalse(add(60)) }
        XCTAssertFalse(add(60, after: 3600))
        for _ in 0..<18 { XCTAssertFalse(add(60)) }
        XCTAssertTrue(add(60))
    }

    func testIgnoredKeyboards() {
        XCTAssertTrue(KeyboardDevice.isIgnored(productName: "YubiKey OTP+FIDO+CCID"))
        XCTAssertTrue(KeyboardDevice.isIgnored(productName: "Security Key", manufacturer: "Yubico"))
        XCTAssertTrue(KeyboardDevice.isIgnored(productName: "TouchBarUserDevice"))
        XCTAssertFalse(KeyboardDevice.isIgnored(productName: "Apple Internal Keyboard / Trackpad", manufacturer: "Apple Inc."))
    }

    func testLegacySettingsStillDecode() throws {
        let legacy = #"{"deviceGUID":"abc","deviceToken":"tok","configured":true,"nannyEnabled":true,"leaderboardName":"Zed"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(s.deviceGUID, "abc")
        XCTAssertEqual(s.leaderboardName, "Zed")
        XCTAssertTrue(s.nannyEnabled)
        XCTAssertEqual(s.nannyRules, NannyRules())
        XCTAssertFalse(s.mistressEnabled)
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
    }
}

final class MistressTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func testWarningThenLockThenDone() {
        var e = EnforcementEngine()
        e.request(devices: [.keyboard], reason: "r", lockSeconds: 300, warningSeconds: 120, now: t0)
        XCTAssertEqual(e.active.first?.phase, .warning)
        XCTAssertTrue(e.lockedDevices.isEmpty)
        XCTAssertFalse(e.tick(now: t0.addingTimeInterval(119)))
        XCTAssertTrue(e.tick(now: t0.addingTimeInterval(120)))
        XCTAssertEqual(e.active.first?.phase, .locked)
        XCTAssertEqual(e.lockedDevices, [.keyboard])
        XCTAssertEqual(e.active.first?.remaining(at: t0.addingTimeInterval(120)), 300)
        XCTAssertFalse(e.tick(now: t0.addingTimeInterval(419)))
        XCTAssertTrue(e.tick(now: t0.addingTimeInterval(420)))
        XCTAssertTrue(e.active.isEmpty)
    }

    func testJustFiveMoreMinutes() {
        var e = EnforcementEngine()
        e.request(devices: [.keyboard], reason: "r", lockSeconds: 300, warningSeconds: 120, now: t0)
        let id = e.active[0].id
        XCTAssertTrue(e.extendWarning(id: id, by: 300))
        XCTAssertFalse(e.tick(now: t0.addingTimeInterval(121)))
        XCTAssertTrue(e.tick(now: t0.addingTimeInterval(420)))
        XCTAssertEqual(e.active.first?.phase, .locked)
        XCTAssertFalse(e.extendWarning(id: id, by: 300))
    }

    func testEndLockEarlyOnlyWhenLocked() {
        var e = EnforcementEngine()
        e.request(devices: [.pointer], reason: "r", lockSeconds: 300, warningSeconds: 60, now: t0)
        let id = e.active[0].id
        XCTAssertFalse(e.endLock(id: id))
        e.tick(now: t0.addingTimeInterval(60))
        XCTAssertTrue(e.endLock(id: id))
        XCTAssertTrue(e.active.isEmpty)
    }

    func testEnforcementsRunSideBySideAndDedupe() {
        var e = EnforcementEngine()
        e.request(devices: [.keyboard], reason: "kb", lockSeconds: 60, warningSeconds: 30, now: t0)
        e.request(devices: [.keyboard], reason: "kb", lockSeconds: 60, warningSeconds: 30, now: t0)
        e.request(devices: [.pointer], reason: "mouse", lockSeconds: 60, warningSeconds: 30, now: t0)
        XCTAssertEqual(e.active.count, 2)
        // Delaying the mouse warning doesn't hold up the keyboard.
        XCTAssertTrue(e.extendWarning(id: e.active[1].id, by: 300))
        e.tick(now: t0.addingTimeInterval(30))
        XCTAssertEqual(e.lockedDevices, [.keyboard])
        XCTAssertEqual(e.active[1].phase, .warning)
        e.tick(now: t0.addingTimeInterval(90))
        XCTAssertEqual(e.active.map(\.reason), ["mouse"])
        e.tick(now: t0.addingTimeInterval(330))
        XCTAssertEqual(e.lockedDevices, [.pointer])
    }

    func testOneEnforcementPerDevice() {
        var e = EnforcementEngine()
        // A Nanny break asks for both devices: that's one card each.
        e.request(devices: [.keyboard, .pointer], reason: "break", lockSeconds: 300, warningSeconds: 60, now: t0)
        XCTAssertEqual(e.active.map(\.device), [.keyboard, .pointer])
        // A later keyboard request merges into the running one without resetting its clock...
        e.request(devices: [.keyboard], reason: "kb", lockSeconds: 120, warningSeconds: 60, now: t0.addingTimeInterval(30))
        XCTAssertEqual(e.active.count, 2)
        XCTAssertEqual(e.active[0].phaseEnds, t0.addingTimeInterval(60))
        XCTAssertEqual(e.active[0].lockSeconds, 300)
        // ...but a longer lock wins, including for a lock already running.
        e.tick(now: t0.addingTimeInterval(60))
        e.request(devices: [.pointer], reason: "mouse", lockSeconds: 600, warningSeconds: 60, now: t0.addingTimeInterval(90))
        XCTAssertEqual(e.active[1].lockSeconds, 600)
        XCTAssertEqual(e.active[1].phaseEnds, t0.addingTimeInterval(660))
        XCTAssertEqual(e.active[0].phaseEnds, t0.addingTimeInterval(360))
    }

    func testSafeWord() {
        var w = SafeWord()
        XCTAssertFalse("uncl".map { w.key($0) }.contains(true))
        XCTAssertTrue(w.key("e"))
        // Other keys in between break it; leading junk doesn't.
        XCTAssertFalse("xxunc".map { w.key($0) }.contains(true))
        XCTAssertFalse(w.key(nil))
        XCTAssertFalse("le".map { w.key($0) }.contains(true))
        XCTAssertEqual("xUNCLE".map { w.key($0) }.last, true)
    }

    func testSchedulerRollingMinutes() {
        var rules = MistressRules()
        rules.keyboardLockEnabled = true
        rules.keyboardEveryMinutes = 3
        rules.keyboardLockMinutes = 7
        var s = LockoutScheduler()
        let typing = Activity(keyActiveSeconds: 10)
        XCTAssertEqual(s.ingest(minuteStart: 0, activity: typing, rules: rules), [])
        XCTAssertEqual(s.ingest(minuteStart: 0, activity: typing, rules: rules), []) // same minute: not double counted
        XCTAssertEqual(s.ingest(minuteStart: 60, activity: Activity(), rules: rules), []) // idle minute doesn't count
        XCTAssertEqual(s.ingest(minuteStart: 120, activity: typing, rules: rules), [])
        XCTAssertEqual(s.ingest(minuteStart: 180, activity: typing, rules: rules),
                       [LockoutScheduler.Trip(device: .keyboard, lockMinutes: 7)])
        XCTAssertEqual(s.ingest(minuteStart: 240, activity: typing, rules: rules), [])
    }

    /// Use during a warning or lockout doesn't count toward the next break.
    func testSchedulerPausesWhileEnforced() {
        var rules = MistressRules()
        rules.keyboardLockEnabled = true
        rules.keyboardEveryMinutes = 3
        var s = LockoutScheduler()
        let typing = Activity(keyActiveSeconds: 10)
        XCTAssertEqual(s.ingest(minuteStart: 0, activity: typing, rules: rules), [])
        XCTAssertEqual(s.ingest(minuteStart: 60, activity: typing, rules: rules), [])
        XCTAssertEqual(s.ingest(minuteStart: 120, activity: typing, rules: rules).count, 1)
        for m in 3..<20 {
            XCTAssertEqual(s.ingest(minuteStart: Int64(m * 60), activity: typing, rules: rules, enforced: [.keyboard]), [])
        }
        XCTAssertEqual(s.ingest(minuteStart: 1200, activity: typing, rules: rules), [])
        XCTAssertEqual(s.ingest(minuteStart: 1260, activity: typing, rules: rules), [])
        XCTAssertEqual(s.ingest(minuteStart: 1320, activity: typing, rules: rules).count, 1)
    }

    func testSchedulerIgnoresDisabledDevicesAndKeepsTripsSeparate() {
        var rules = MistressRules()
        rules.keyboardLockEnabled = true
        rules.keyboardEveryMinutes = 1
        rules.keyboardLockMinutes = 2
        rules.mouseLockEnabled = true
        rules.mouseEveryMinutes = 1
        rules.mouseLockMinutes = 4
        var s = LockoutScheduler()
        // Each device gets its own lock length, even when both trip in the same minute.
        XCTAssertEqual(s.ingest(minuteStart: 0, activity: Activity(keyActiveSeconds: 1, pointerActiveSeconds: 1), rules: rules),
                       [LockoutScheduler.Trip(device: .keyboard, lockMinutes: 2), LockoutScheduler.Trip(device: .pointer, lockMinutes: 4)])
        rules.keyboardLockEnabled = false
        XCTAssertEqual(s.ingest(minuteStart: 60, activity: Activity(keyActiveSeconds: 1), rules: rules), [])
    }
}
