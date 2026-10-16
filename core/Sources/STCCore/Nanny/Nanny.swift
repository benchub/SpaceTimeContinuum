import Foundation

/// User-adjustable Nanny rules. Each rule can be switched on and tuned separately.
public struct NannyRules: Codable, Equatable, Sendable {
    /// Break when the screen has been on (and unlocked) for the whole of the last `screenOnHours`.
    public var screenOnBreakEnabled = true
    public var screenOnHours = 2
    /// Break when at least `activityPercent`% of the minutes in the last `activityWindowHours` saw input.
    public var activityBreakEnabled = true
    public var activityPercent = 80
    public var activityWindowHours = 1
    /// Stretch every `stretchEveryMinutes` minutes of screen-on time.
    public var stretchEnabled = false
    public var stretchEveryMinutes = 30

    public init() {}
}

/// Decides when to suggest a break.
///
/// By default "too much" is either:
/// - keyboard or pointer activity in at least 48 of the last 60 minutes (80%), or
/// - screen on and unlocked for the whole of the last 2 hours.
public struct Nanny: Sendable {
    public enum Reason: Equatable, Sendable {
        case busyHour(activeMinutes: Int, windowMinutes: Int)
        case longSession(minutes: Int)
    }

    public var activityEnabled = true
    public var sessionEnabled = true
    public var activeWindowMinutes = 60
    public var activeMinutesThreshold = 48
    public var sessionWindowMinutes = 120
    /// A minute counts as "screen on and unlocked" if at least this many of its seconds were.
    /// Slightly under 60 to tolerate the odd missed timer tick.
    public var attentiveSecondsPerMinute = 55
    /// Don't nag more than once per this many seconds.
    public var cooldown: TimeInterval = 3600

    public init() {}

    public init(rules: NannyRules) {
        activityEnabled = rules.activityBreakEnabled
        sessionEnabled = rules.screenOnBreakEnabled
        activeWindowMinutes = max(1, rules.activityWindowHours) * 60
        activeMinutesThreshold = max(1, (activeWindowMinutes * rules.activityPercent + 99) / 100)
        sessionWindowMinutes = max(1, rules.screenOnHours) * 60
    }

    /// Minutes of history `evaluate` needs.
    public var historyMinutes: Int { max(activeWindowMinutes, sessionWindowMinutes) }

    /// - Parameter recent: minute rows covering at least `historyMinutes`.
    public func evaluate(recent: [MinuteRollup], now: Date, lastNagAt: Date?) -> Reason? {
        if let last = lastNagAt, now.timeIntervalSince(last) < cooldown { return nil }
        let nowMinute = Int64(now.timeIntervalSince1970) / 60 * 60
        let byMinute = Dictionary(recent.map { ($0.minuteStart, $0.activity) }, uniquingKeysWith: { $0.mergedWithinMinute($1) })

        if activityEnabled {
            let activeStart = nowMinute - Int64(activeWindowMinutes * 60)
            let active = byMinute.filter { $0.key >= activeStart && $0.key < nowMinute && $0.value.anyActiveSeconds > 0 }.count
            if active >= activeMinutesThreshold { return .busyHour(activeMinutes: active, windowMinutes: activeWindowMinutes) }
        }

        if sessionEnabled {
            let sessionStart = nowMinute - Int64(sessionWindowMinutes * 60)
            let allAttentive = stride(from: sessionStart, to: nowMinute, by: 60).allSatisfy {
                (byMinute[$0]?.attentiveSeconds ?? 0) >= attentiveSecondsPerMinute
            }
            if allAttentive { return .longSession(minutes: sessionWindowMinutes) }
        }
        return nil
    }

    public static let suggestions = [
        "Go enjoy 5 minutes of life elsewhere.",
        "The rest of the universe misses you. Go visit it for 5 minutes.",
        "Stand up, stretch, look at something more than an arm's length away. 5 minutes. Go.",
        "Your keyboard needs a rest even if you don't. Take 5.",
        "Spacetime will still be here in 5 minutes. Go get some air.",
        "Hydrate. Wander. Pet something. Back in 5.",
    ]

    public static let stretchSuggestions = [
        "Stand up and reach for the ceiling.",
        "Roll your shoulders, shake out your wrists, look out a window.",
        "Stretch your back, your neck and your fingers. 30 seconds is plenty.",
        "Unfold yourself. Your spine will thank you.",
    ]

    /// Length of the break the suggestions ask for.
    public static let breakMinutes = 5

    public static func message(for reason: Reason) -> (title: String, body: String) {
        let title: String
        switch reason {
        case .busyHour(let m, let window):
            title = window == 60 ? "Busy hour: active \(m) of the last 60 minutes" : "Busy stretch: active \(m) of the last \(window) minutes"
        case .longSession(let minutes):
            let hours = minutes / 60
            title = "You've been at it for \(hours == 1 ? "an hour" : "\(hours) hours") straight"
        }
        return (title, suggestions.randomElement()!)
    }

    /// - Parameter body: the quip to show, normally from `QuipRotation.next`.
    public static func stretchMessage(body: String? = nil) -> (title: String, body: String) {
        ("Time for a stretch", body ?? stretchSuggestions.randomElement()!)
    }
}

/// Picks quips at random without repeating any until the whole pool has been used.
public struct QuipRotation: Sendable {
    private var used = Set<String>()
    private var last: String?

    public init() {}

    public mutating func next(from pool: [String]) -> String? {
        guard !pool.isEmpty else { return nil }
        var fresh = pool.filter { !used.contains($0) }
        if fresh.isEmpty {
            used = []
            fresh = pool.count > 1 ? pool.filter { $0 != last } : pool
        }
        let pick = fresh.randomElement()!
        used.insert(pick)
        last = pick
        return pick
    }
}

/// Counts screen-on time and says when it's time for a stretch.
public struct StretchTracker: Sendable {
    private var screenOnSeconds = 0

    public init() {}

    /// Adds screen-on seconds; returns true (and starts over) once `everyMinutes` have accumulated.
    public mutating func add(screenOnSeconds seconds: Int, everyMinutes: Int) -> Bool {
        screenOnSeconds += max(0, seconds)
        guard everyMinutes > 0, screenOnSeconds >= everyMinutes * 60 else { return false }
        screenOnSeconds = 0
        return true
    }

    public mutating func reset() { screenOnSeconds = 0 }
}
