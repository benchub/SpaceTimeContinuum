import Foundation

/// Decides when to suggest a break.
///
/// "Too much" is either:
/// - keyboard or pointer activity in at least 48 of the last 60 minutes (80%), or
/// - screen on and unlocked for the whole of the last 2 hours.
public struct Nanny: Sendable {
    public enum Reason: Equatable, Sendable {
        case busyHour(activeMinutes: Int)
        case longSession(minutes: Int)
    }

    public var activeWindowMinutes = 60
    public var activeMinutesThreshold = 48
    public var sessionWindowMinutes = 120
    /// A minute counts as "screen on and unlocked" if at least this many of its seconds were.
    /// Slightly under 60 to tolerate the odd missed timer tick.
    public var attentiveSecondsPerMinute = 55
    /// Don't nag more than once per this many seconds.
    public var cooldown: TimeInterval = 3600

    public init() {}

    /// - Parameter recent: minute rows covering at least the last `sessionWindowMinutes`.
    public func evaluate(recent: [MinuteRollup], now: Date, lastNagAt: Date?) -> Reason? {
        if let last = lastNagAt, now.timeIntervalSince(last) < cooldown { return nil }
        let nowMinute = Int64(now.timeIntervalSince1970) / 60 * 60
        let byMinute = Dictionary(recent.map { ($0.minuteStart, $0.activity) }, uniquingKeysWith: { $0.mergedWithinMinute($1) })

        let activeStart = nowMinute - Int64(activeWindowMinutes * 60)
        let active = byMinute.filter { $0.key >= activeStart && $0.key < nowMinute && $0.value.anyActiveSeconds > 0 }.count
        if active >= activeMinutesThreshold { return .busyHour(activeMinutes: active) }

        let sessionStart = nowMinute - Int64(sessionWindowMinutes * 60)
        let allAttentive = stride(from: sessionStart, to: nowMinute, by: 60).allSatisfy {
            (byMinute[$0]?.attentiveSeconds ?? 0) >= attentiveSecondsPerMinute
        }
        if allAttentive { return .longSession(minutes: sessionWindowMinutes) }
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

    public static func message(for reason: Reason) -> (title: String, body: String) {
        let title: String
        switch reason {
        case .busyHour(let m): title = "Busy hour: active \(m) of the last 60 minutes"
        case .longSession: title = "You've been at it for 2 hours straight"
        }
        return (title, suggestions.randomElement()!)
    }
}
