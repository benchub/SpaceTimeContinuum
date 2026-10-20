import Foundation

public enum InputDevice: String, Codable, Sendable, Hashable, CaseIterable {
    case keyboard, pointer
}

/// User-adjustable Mistress Mode rules. Each rule can be switched on and tuned separately.
public struct MistressRules: Codable, Equatable, Sendable {
    /// Warning before any enforcement (Nanny suggestions are always enforced in Mistress Mode).
    public var warningMinutes = 2
    public var keyboardLockEnabled = false
    public var keyboardLockMinutes = 5
    public var keyboardEveryMinutes = 60
    public var mouseLockEnabled = false
    public var mouseLockMinutes = 5
    public var mouseEveryMinutes = 60
    /// Adds an "end it early" button to the lockout counter.
    public var safeWordEnabled = false

    public init() {}
}

/// Rolling "x minutes off for every y minutes of use" scheduling.
public struct LockoutScheduler: Sendable {
    public struct Trip: Equatable, Sendable {
        public var device: InputDevice
        public var lockMinutes: Int
    }

    private var usedMinutes: [InputDevice: Int] = [:]
    private var lastCountedMinute: [InputDevice: Int64] = [:]

    public init() {}

    /// Counts the minute as used for each device that saw input, and reports devices that reached
    /// their limit, each with its own lock length.
    public mutating func ingest(minuteStart: Int64, activity: Activity, rules: MistressRules) -> [Trip] {
        var trips: [Trip] = []
        for device in InputDevice.allCases {
            let enabled = device == .keyboard ? rules.keyboardLockEnabled : rules.mouseLockEnabled
            let every = device == .keyboard ? rules.keyboardEveryMinutes : rules.mouseEveryMinutes
            let lock = device == .keyboard ? rules.keyboardLockMinutes : rules.mouseLockMinutes
            let seconds = device == .keyboard ? activity.keyActiveSeconds : activity.pointerActiveSeconds
            guard enabled else { usedMinutes[device] = 0; continue }
            if seconds > 0, lastCountedMinute[device] != minuteStart {
                lastCountedMinute[device] = minuteStart
                usedMinutes[device, default: 0] += 1
            }
            if usedMinutes[device, default: 0] >= max(1, every) {
                usedMinutes[device] = 0
                trips.append(Trip(device: device, lockMinutes: lock))
            }
        }
        return trips
    }

    public mutating func reset() {
        usedMinutes = [:]
        lastCountedMinute = [:]
    }
}

/// A warning countdown followed by a lockout, for one device.
public struct Enforcement: Equatable, Sendable, Identifiable {
    public enum Phase: Equatable, Sendable { case warning, locked }

    public var id: Int
    public var device: InputDevice
    public var reason: String
    public var lockSeconds: TimeInterval
    public var phase: Phase
    public var phaseEnds: Date

    public func remaining(at now: Date) -> TimeInterval { max(0, phaseEnds.timeIntervalSince(now)) }
}

/// Runs at most one enforcement per device, side by side; each has its own warning and lockout
/// clock, so delaying one never holds up another.
public struct EnforcementEngine: Sendable {
    public private(set) var active: [Enforcement] = []
    private var nextID = 1

    public init() {}

    /// Devices blocked right now, by enforcements in their lockout phase.
    public var lockedDevices: Set<InputDevice> {
        Set(active.filter { $0.phase == .locked }.map(\.device))
    }

    /// Starts a warning for each device. A device that already has one running keeps it (its
    /// clock isn't reset), but its lock grows if this request asks for a longer one.
    public mutating func request(devices: Set<InputDevice>, reason: String, lockSeconds: TimeInterval,
                                 warningSeconds: TimeInterval, now: Date) {
        for device in InputDevice.allCases where devices.contains(device) {
            if let i = active.firstIndex(where: { $0.device == device }) {
                if lockSeconds > active[i].lockSeconds {
                    if active[i].phase == .locked { active[i].phaseEnds.addTimeInterval(lockSeconds - active[i].lockSeconds) }
                    active[i].lockSeconds = lockSeconds
                }
                continue
            }
            active.append(Enforcement(id: nextID, device: device, reason: reason, lockSeconds: lockSeconds,
                                      phase: .warning, phaseEnds: now.addingTimeInterval(warningSeconds)))
            nextID += 1
        }
    }

    /// Advances every enforcement whose phase time is up. Returns true when anything changed.
    @discardableResult
    public mutating func tick(now: Date) -> Bool {
        var changed = false
        var remaining: [Enforcement] = []
        for var e in active {
            if now >= e.phaseEnds {
                changed = true
                if e.phase == .locked { continue }
                e.phase = .locked
                e.phaseEnds = now.addingTimeInterval(e.lockSeconds)
            }
            remaining.append(e)
        }
        active = remaining
        return changed
    }

    /// Pushes the end of a warning back. Returns false if that enforcement isn't in its warning phase.
    @discardableResult
    public mutating func extendWarning(id: Int, by seconds: TimeInterval) -> Bool {
        guard let i = active.firstIndex(where: { $0.id == id && $0.phase == .warning }) else { return false }
        active[i].phaseEnds.addTimeInterval(seconds)
        return true
    }

    /// Ends a running lockout early. Returns false if that enforcement isn't locked.
    @discardableResult
    public mutating func endLock(id: Int) -> Bool {
        guard let i = active.firstIndex(where: { $0.id == id && $0.phase == .locked }) else { return false }
        active.remove(at: i)
        return true
    }

    /// Ends every running lockout (e.g. when blocking turns out to be impossible).
    public mutating func endAllLocks() {
        active.removeAll { $0.phase == .locked }
    }

    public mutating func cancelAll() {
        active.removeAll()
    }
}
