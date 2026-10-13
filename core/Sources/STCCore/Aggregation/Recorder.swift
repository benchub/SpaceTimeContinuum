import Foundation

/// Platform-independent recording engine.
///
/// Platform input monitors call `recordKeyPress` / `recordPointerMovement` from any thread.
/// The host calls `tick(now:)` about once per second; each tick closes the second that just
/// ended and, at a minute boundary, emits a `MinuteRollup` through `onMinute`.
public final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingKeyPresses = 0
    private var pendingKeyDistance = 0.0
    private var pendingPointerDistance = 0.0
    private var buffer = MinuteBuffer()
    private var lastClosedSecond: Int64?
    private let session: SessionStateProviding

    /// Called (on the thread calling `tick`/`flush`) for each completed minute.
    public var onMinute: ((MinuteRollup) -> Void)?

    public init(session: SessionStateProviding) {
        self.session = session
    }

    public func recordKeyPress(travelMeters: Double) {
        lock.lock()
        pendingKeyPresses += 1
        pendingKeyDistance += max(0, travelMeters)
        lock.unlock()
    }

    public func recordPointerMovement(meters: Double) {
        guard meters > 0, meters.isFinite else { return }
        lock.lock()
        pendingPointerDistance += meters
        lock.unlock()
    }

    /// Closes the second that ended just before `now`.
    public func tick(now: Date = Date()) {
        let second = Int64(floor(now.timeIntervalSince1970)) - 1
        let screenOn = session.isScreenOn
        let unlocked = session.isUnlocked

        lock.lock()
        if let last = lastClosedSecond, second <= last {
            // Timer fired early or twice in one second; keep accumulating.
            lock.unlock()
            return
        }
        let sample = SecondSample(
            second: second,
            screenOn: screenOn,
            unlocked: unlocked,
            keyPresses: pendingKeyPresses,
            keyDistanceMeters: pendingKeyDistance,
            pointerDistanceMeters: pendingPointerDistance
        )
        pendingKeyPresses = 0
        pendingKeyDistance = 0
        pendingPointerDistance = 0
        lastClosedSecond = second
        let completed = buffer.append(sample)
        lock.unlock()

        if let completed { onMinute?(completed) }
    }

    /// Emits the partial current minute (e.g. on quit or before sleep).
    public func flush() {
        lock.lock()
        let partial = buffer.flush()
        lock.unlock()
        if let partial { onMinute?(partial) }
    }

    /// Activity recorded in the not-yet-written current minute.
    public var currentMinuteActivity: Activity {
        lock.lock()
        defer { lock.unlock() }
        return buffer.rollup()?.activity ?? .zero
    }

    /// Discards in-memory data (used by reset).
    public func discard() {
        lock.lock()
        buffer = MinuteBuffer()
        pendingKeyPresses = 0
        pendingKeyDistance = 0
        pendingPointerDistance = 0
        lock.unlock()
    }
}
