import Foundation

/// Holds at most one minute of per-second samples. When a sample from a new minute
/// arrives, the previous minute is rolled up and returned.
public struct MinuteBuffer: Sendable {
    public private(set) var minuteStart: Int64?
    public private(set) var samples: [SecondSample] = []

    public init() {}

    /// Appends a sample. Returns the rollup of the previous minute if this sample starts a new one.
    public mutating func append(_ sample: SecondSample) -> MinuteRollup? {
        var completed: MinuteRollup?
        if let current = minuteStart, current != sample.minuteStart {
            completed = rollup()
            samples.removeAll(keepingCapacity: true)
        }
        minuteStart = sample.minuteStart
        if let last = samples.last, last.second == sample.second {
            samples[samples.count - 1].keyPresses += sample.keyPresses
            samples[samples.count - 1].keyDistanceMeters += sample.keyDistanceMeters
            samples[samples.count - 1].pointerDistanceMeters += sample.pointerDistanceMeters
        } else {
            samples.append(sample)
        }
        return completed
    }

    /// Rollup of whatever is in the buffer (possibly a partial minute).
    public func rollup() -> MinuteRollup? {
        guard let start = minuteStart, !samples.isEmpty else { return nil }
        let activity = samples.reduce(Activity.zero) { $0 + Activity(second: $1) }
        return MinuteRollup(minuteStart: start, activity: activity)
    }

    /// Returns the partial rollup and empties the buffer.
    public mutating func flush() -> MinuteRollup? {
        let r = rollup()
        samples.removeAll()
        minuteStart = nil
        return r
    }
}
