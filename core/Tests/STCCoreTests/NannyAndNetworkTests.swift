import XCTest
@testable import STCCore

final class NannyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_760_007_210) // mid-minute

    func rows(_ minutes: Int, active: (Int) -> Bool, attentive: Int = 60) -> [MinuteRollup] {
        let nowMinute = Int64(now.timeIntervalSince1970) / 60 * 60
        return (1...minutes).map { i in
            MinuteRollup(minuteStart: nowMinute - Int64(i * 60), activity: Activity(
                screenOnSeconds: attentive, unlockedSeconds: attentive, attentiveSeconds: attentive,
                keyActiveSeconds: active(i) ? 5 : 0, anyActiveSeconds: active(i) ? 5 : 0))
        }
    }

    func testBusyHour() {
        let nanny = Nanny()
        // 48 of the last 60 minutes active (12 idle), with a gap so the 2-hour rule doesn't fire.
        let recent = rows(60, active: { $0 > 12 }, attentive: 30)
        XCTAssertEqual(nanny.evaluate(recent: recent, now: now, lastNagAt: nil), .busyHour(activeMinutes: 48, windowMinutes: 60))
        let lazier = rows(60, active: { $0 > 13 }, attentive: 30)
        XCTAssertNil(nanny.evaluate(recent: lazier, now: now, lastNagAt: nil))
    }

    func testLongSessionAndCooldown() {
        let nanny = Nanny()
        let recent = rows(120, active: { _ in false })
        XCTAssertEqual(nanny.evaluate(recent: recent, now: now, lastNagAt: nil), .longSession(minutes: 120))
        XCTAssertNil(nanny.evaluate(recent: recent, now: now, lastNagAt: now.addingTimeInterval(-600)))
        var gap = recent
        gap.remove(at: 50)
        XCTAssertNil(nanny.evaluate(recent: gap, now: now, lastNagAt: nil))
    }
}

struct StubTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, [String: String], String)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }
}

final class LeaderboardClientTests: XCTestCase {
    func client(_ handler: @escaping @Sendable (URLRequest) -> (Int, [String: String], String)) -> LeaderboardClient {
        LeaderboardClient(transport: StubTransport(handler: handler), userAgent: "SpaceTimeContinuum/test")
    }

    func testUploadRequestAndResponse() async throws {
        let c = client { req in
            XCTAssertEqual(req.url?.absoluteString, "https://spacetime.silentmedia.com/sample/abc")
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-STC-Token"), "tok")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-STC-Protocol"), "1")
            let json = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            let samples = json["samples"] as! [[String: Any]]
            XCTAssertEqual(samples.first?["minute_start"] as? Int, 120)
            XCTAssertEqual(samples.first?["key_presses"] as? Int, 3)
            return (200, [:], #"{"status":"ok","accepted":[120],"rejected":[{"minute_start":180,"reason":"bad"}]}"#)
        }
        let r = try await c.upload(guid: "abc", token: "tok", samples: [
            MinuteRollup(minuteStart: 120, activity: Activity(keyPresses: 3)),
            MinuteRollup(minuteStart: 180, activity: .zero),
        ], utcOffsetSeconds: 0)
        XCTAssertEqual(r.accepted, [120])
        XCTAssertEqual(r.rejected, [180: "bad"])
    }

    func testErrorsAndNames() async throws {
        let c = client { req in
            let path = req.url!.path
            if path.hasPrefix("/check/") {
                XCTAssertTrue(req.url!.absoluteString.hasSuffix("/check/g/Space%20Cadet"))
                return (200, [:], #"{"name":"Space Cadet","available":false,"reason":"taken"}"#)
            }
            if path.hasPrefix("/name/") { return (409, [:], #"{"status":"unavailable","name":"Space Cadet"}"#) }
            return (429, ["Retry-After": "60"], #"{"status":"error","message":"slow down"}"#)
        }
        let check = try await c.checkName(guid: "g", name: "Space Cadet")
        XCTAssertFalse(check.available)
        XCTAssertEqual(check.reason, "taken")
        let claim = await c.claimName(guid: "g", token: "t", name: "Space Cadet")
        XCTAssertEqual(claim, .unavailable(name: "Space Cadet"))
        do {
            _ = try await c.upload(guid: "g", token: "t", samples: [], utcOffsetSeconds: 0)
            XCTFail("expected error")
        } catch let e as LeaderboardClient.ClientError {
            XCTAssertEqual(e, .http(status: 429, message: "slow down", retryAfter: 60))
        }
    }

    func testNameRules() {
        XCTAssertTrue(LeaderboardName.isValid("Space Cadet"))
        XCTAssertTrue(LeaderboardName.isValid("abc"))
        XCTAssertFalse(LeaderboardName.isValid("ab"))
        XCTAssertFalse(LeaderboardName.isValid(" abc"))
        XCTAssertFalse(LeaderboardName.isValid("abc-"))
        XCTAssertFalse(LeaderboardName.isValid("emoji🚀ok"))
        XCTAssertFalse(LeaderboardName.isValid(String(repeating: "a", count: 25)))
    }

    @MainActor
    func testNameCheckerDebounces() async throws {
        let counter = Counter()
        let c = client { req in
            counter.increment(req.url!.lastPathComponent)
            return (200, [:], #"{"available":true}"#)
        }
        let checker = NameAvailabilityChecker(client: c, guid: { "g" }, minimumInterval: 0.3)
        checker.update("abc")
        checker.update("abcd")
        checker.update("abcde")
        try await Task.sleep(nanoseconds: 100_000_000)
        checker.update("abcdef")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        // First request fires immediately with the latest text, then one more with the final text.
        XCTAssertEqual(counter.names, ["abcde", "abcdef"])
        XCTAssertEqual(checker.state, .available)
        checker.update("x")
        XCTAssertEqual(checker.state, .invalid)
    }

    @MainActor
    func testSyncMarksAcceptedAndRejected() async throws {
        let previous = Features.leaderboardAvailable
        Features.leaderboardAvailable = true
        defer { Features.leaderboardAvailable = previous }
        let store = try ActivityStore(path: ":memory:")
        for i in 0..<3 { try store.record(MinuteRollup(minuteStart: Int64(1_760_000_040 + i * 60), activity: .zero)) }
        let c = client { _ in (200, [:], #"{"accepted":[1760000040,1760000100],"rejected":[{"minute_start":1760000160,"reason":"x"}]}"#) }
        var settings = AppSettings()
        settings.leaderboardEnabled = true
        let sync = SyncService(store: store, client: c, session: SessionStub(), settings: { settings })
        let marked = await sync.syncNow()
        XCTAssertEqual(marked, 3)
        XCTAssertTrue(try store.unuploadedMinutes(limit: 10).isEmpty)

        settings.leaderboardEnabled = false
        try store.record(MinuteRollup(minuteStart: 1_760_000_220, activity: .zero))
        let none = await sync.syncNow()
        XCTAssertEqual(none, 0)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var names: [String] = []
    func increment(_ name: String) {
        lock.lock(); names.append(name); lock.unlock()
    }
}
