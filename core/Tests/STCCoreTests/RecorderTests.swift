import XCTest
@testable import STCCore

final class SessionStub: SessionStateProviding {
    var isScreenOn = true
    var isUnlocked = true
}

final class RecorderTests: XCTestCase {
    func testSecondsRollIntoMinute() {
        let session = SessionStub()
        let recorder = Recorder(session: session)
        var minutes: [MinuteRollup] = []
        recorder.onMinute = { minutes.append($0) }

        let base: TimeInterval = 1_760_000_040 // multiple of 60
        // Second 0: two key presses; second 1: pointer only; second 2: nothing, locked.
        recorder.recordKeyPress(travelMeters: 0.002)
        recorder.recordKeyPress(travelMeters: 0.002)
        recorder.tick(now: Date(timeIntervalSince1970: base + 1.05))
        recorder.recordPointerMovement(meters: 0.5)
        recorder.tick(now: Date(timeIntervalSince1970: base + 2.05))
        session.isUnlocked = false
        recorder.tick(now: Date(timeIntervalSince1970: base + 3.05))
        XCTAssertTrue(minutes.isEmpty)

        // First tick of the next minute closes second 59 of this minute; the one after starts the next minute.
        recorder.tick(now: Date(timeIntervalSince1970: base + 60.05))
        XCTAssertTrue(minutes.isEmpty)
        recorder.tick(now: Date(timeIntervalSince1970: base + 61.05))
        XCTAssertEqual(minutes.count, 1)
        let m = minutes[0]
        XCTAssertEqual(m.minuteStart, Int64(base))
        XCTAssertEqual(m.activity.keyPresses, 2)
        XCTAssertEqual(m.activity.keyActiveSeconds, 1)
        XCTAssertEqual(m.activity.keyDistanceMeters, 0.004, accuracy: 1e-9)
        XCTAssertEqual(m.activity.pointerActiveSeconds, 1)
        XCTAssertEqual(m.activity.pointerDistanceMeters, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.activity.anyActiveSeconds, 2)
        XCTAssertEqual(m.activity.screenOnSeconds, 4)
        XCTAssertEqual(m.activity.unlockedSeconds, 2)
        XCTAssertEqual(m.activity.attentiveSeconds, 2)
    }

    func testDuplicateTickInSameSecondKeepsAccumulating() {
        let recorder = Recorder(session: SessionStub())
        var minutes: [MinuteRollup] = []
        recorder.onMinute = { minutes.append($0) }
        let base: TimeInterval = 1_760_000_040
        recorder.recordKeyPress(travelMeters: 0.001)
        recorder.tick(now: Date(timeIntervalSince1970: base + 1.01))
        recorder.recordKeyPress(travelMeters: 0.001)
        recorder.tick(now: Date(timeIntervalSince1970: base + 1.99)) // same second, ignored
        recorder.tick(now: Date(timeIntervalSince1970: base + 2.01))
        recorder.flush()
        XCTAssertEqual(minutes.first?.activity.keyPresses, 2)
        XCTAssertEqual(minutes.first?.activity.keyActiveSeconds, 2)
    }

    func testCurrentMinuteActivity() {
        let recorder = Recorder(session: SessionStub())
        recorder.recordPointerMovement(meters: 1)
        recorder.tick(now: Date(timeIntervalSince1970: 1_760_000_041.1))
        XCTAssertEqual(recorder.currentMinuteActivity.pointerDistanceMeters, 1)
    }
}

final class PointerOdometerTests: XCTestCase {
    func testMixedDensityDisplays() {
        // Retina laptop: 1512x982 points over 302x196 mm. External 1x: 2560x1440 points over 597x336 mm.
        let laptop = DisplayGeometry(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), physicalSizeMM: CGSize(width: 302, height: 196))
        let external = DisplayGeometry(id: 2, bounds: CGRect(x: 1512, y: 0, width: 2560, height: 1440), physicalSizeMM: CGSize(width: 597, height: 336))
        var odo = PointerOdometer(displays: [laptop, external])
        _ = odo.move(to: CGPoint(x: 100, y: 100))
        let onLaptop = odo.move(to: CGPoint(x: 200, y: 100))
        XCTAssertEqual(onLaptop, 100 * 0.302 / 1512, accuracy: 1e-6)
        odo.reset()
        _ = odo.move(to: CGPoint(x: 2000, y: 100))
        let onExternal = odo.move(to: CGPoint(x: 2100, y: 100))
        XCTAssertEqual(onExternal, 100 * 0.597 / 2560, accuracy: 1e-6)
        XCTAssertNotEqual(onLaptop, onExternal, accuracy: 1e-6)
    }

    func testIgnoresWarpsAndBogusSizes() {
        let tv = DisplayGeometry(id: 3, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), physicalSizeMM: .zero)
        XCTAssertEqual(tv.metersPerPoint.x, DisplayGeometry.fallbackMetersPerPoint)
        var odo = PointerOdometer(displays: [tv])
        _ = odo.move(to: .zero)
        XCTAssertEqual(odo.move(to: CGPoint(x: 1000, y: 0), rawDelta: CGVector(dx: 2, dy: 0)), 0)
        XCTAssertGreaterThan(odo.move(to: CGPoint(x: 1010, y: 0), rawDelta: CGVector(dx: 10, dy: 0)), 0)
    }

    func testRotatedDisplay() {
        let portrait = DisplayGeometry(id: 4, bounds: CGRect(x: 0, y: 0, width: 1440, height: 2560), physicalSizeMM: CGSize(width: 597, height: 336))
        XCTAssertEqual(portrait.metersPerPoint.x, 0.336 / 1440, accuracy: 1e-9)
    }
}
