import Foundation

/// The nine per-minute activity metrics. Used for single minutes and for sums over
/// longer periods (quarter hours, days, lifetime).
public struct Activity: Equatable, Codable, Sendable {
    public var screenOnSeconds: Int = 0
    public var unlockedSeconds: Int = 0
    /// Seconds that were both screen-on and unlocked.
    public var attentiveSeconds: Int = 0
    public var keyActiveSeconds: Int = 0
    public var keyPresses: Int = 0
    public var keyDistanceMeters: Double = 0
    public var pointerActiveSeconds: Int = 0
    public var pointerDistanceMeters: Double = 0
    /// Seconds containing key presses or pointer movement.
    public var anyActiveSeconds: Int = 0

    public init(
        screenOnSeconds: Int = 0,
        unlockedSeconds: Int = 0,
        attentiveSeconds: Int = 0,
        keyActiveSeconds: Int = 0,
        keyPresses: Int = 0,
        keyDistanceMeters: Double = 0,
        pointerActiveSeconds: Int = 0,
        pointerDistanceMeters: Double = 0,
        anyActiveSeconds: Int = 0
    ) {
        self.screenOnSeconds = screenOnSeconds
        self.unlockedSeconds = unlockedSeconds
        self.attentiveSeconds = attentiveSeconds
        self.keyActiveSeconds = keyActiveSeconds
        self.keyPresses = keyPresses
        self.keyDistanceMeters = keyDistanceMeters
        self.pointerActiveSeconds = pointerActiveSeconds
        self.pointerDistanceMeters = pointerDistanceMeters
        self.anyActiveSeconds = anyActiveSeconds
    }

    public static let zero = Activity()

    public init(second s: SecondSample) {
        let keys = s.keyPresses > 0
        let pointer = s.pointerDistanceMeters > 0
        self.init(
            screenOnSeconds: s.screenOn ? 1 : 0,
            unlockedSeconds: s.unlocked ? 1 : 0,
            attentiveSeconds: (s.screenOn && s.unlocked) ? 1 : 0,
            keyActiveSeconds: keys ? 1 : 0,
            keyPresses: s.keyPresses,
            keyDistanceMeters: s.keyDistanceMeters,
            pointerActiveSeconds: pointer ? 1 : 0,
            pointerDistanceMeters: s.pointerDistanceMeters,
            anyActiveSeconds: (keys || pointer) ? 1 : 0
        )
    }

    public static func + (a: Activity, b: Activity) -> Activity {
        Activity(
            screenOnSeconds: a.screenOnSeconds + b.screenOnSeconds,
            unlockedSeconds: a.unlockedSeconds + b.unlockedSeconds,
            attentiveSeconds: a.attentiveSeconds + b.attentiveSeconds,
            keyActiveSeconds: a.keyActiveSeconds + b.keyActiveSeconds,
            keyPresses: a.keyPresses + b.keyPresses,
            keyDistanceMeters: a.keyDistanceMeters + b.keyDistanceMeters,
            pointerActiveSeconds: a.pointerActiveSeconds + b.pointerActiveSeconds,
            pointerDistanceMeters: a.pointerDistanceMeters + b.pointerDistanceMeters,
            anyActiveSeconds: a.anyActiveSeconds + b.anyActiveSeconds
        )
    }

    public static func - (a: Activity, b: Activity) -> Activity {
        Activity(
            screenOnSeconds: a.screenOnSeconds - b.screenOnSeconds,
            unlockedSeconds: a.unlockedSeconds - b.unlockedSeconds,
            attentiveSeconds: a.attentiveSeconds - b.attentiveSeconds,
            keyActiveSeconds: a.keyActiveSeconds - b.keyActiveSeconds,
            keyPresses: a.keyPresses - b.keyPresses,
            keyDistanceMeters: a.keyDistanceMeters - b.keyDistanceMeters,
            pointerActiveSeconds: a.pointerActiveSeconds - b.pointerActiveSeconds,
            pointerDistanceMeters: a.pointerDistanceMeters - b.pointerDistanceMeters,
            anyActiveSeconds: a.anyActiveSeconds - b.anyActiveSeconds
        )
    }

    public static func += (a: inout Activity, b: Activity) { a = a + b }

    /// Merges two partial recordings of the same minute, capping second counters at 60.
    public func mergedWithinMinute(_ other: Activity) -> Activity {
        var m = self + other
        m.screenOnSeconds = min(m.screenOnSeconds, 60)
        m.unlockedSeconds = min(m.unlockedSeconds, 60)
        m.attentiveSeconds = min(m.attentiveSeconds, 60)
        m.keyActiveSeconds = min(m.keyActiveSeconds, 60)
        m.pointerActiveSeconds = min(m.pointerActiveSeconds, 60)
        m.anyActiveSeconds = min(m.anyActiveSeconds, 60)
        return m
    }
}

/// What happened during one wall-clock second.
public struct SecondSample: Equatable, Sendable {
    /// Unix epoch second this sample covers.
    public var second: Int64
    public var screenOn: Bool
    public var unlocked: Bool
    public var keyPresses: Int
    public var keyDistanceMeters: Double
    public var pointerDistanceMeters: Double

    public init(second: Int64, screenOn: Bool, unlocked: Bool, keyPresses: Int = 0,
                keyDistanceMeters: Double = 0, pointerDistanceMeters: Double = 0) {
        self.second = second
        self.screenOn = screenOn
        self.unlocked = unlocked
        self.keyPresses = keyPresses
        self.keyDistanceMeters = keyDistanceMeters
        self.pointerDistanceMeters = pointerDistanceMeters
    }

    public var minuteStart: Int64 { second - ((second % 60) + 60) % 60 }
}

/// One row of the `minutes` table.
public struct MinuteRollup: Equatable, Sendable {
    /// UTC epoch seconds, multiple of 60.
    public var minuteStart: Int64
    public var activity: Activity
    public var uploadedAt: Int64?

    public init(minuteStart: Int64, activity: Activity, uploadedAt: Int64? = nil) {
        self.minuteStart = minuteStart
        self.activity = activity
        self.uploadedAt = uploadedAt
    }
}

/// Lifetime totals, read at startup instead of scanning all minutes.
public struct LifetimeTotals: Equatable, Sendable {
    public var activity: Activity
    /// When tracking began (UTC epoch seconds), nil if nothing recorded yet.
    public var trackingSince: Int64?

    public init(activity: Activity = .zero, trackingSince: Int64? = nil) {
        self.activity = activity
        self.trackingSince = trackingSince
    }
}
