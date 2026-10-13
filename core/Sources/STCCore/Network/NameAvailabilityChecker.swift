import Foundation

/// Checks leaderboard-name availability as the user types.
///
/// Only the most recent text is checked, requests are at least one second apart and never
/// overlap (so at most one response per second), and responses for stale text are dropped.
@MainActor
public final class NameAvailabilityChecker {
    public enum State: Equatable, Sendable {
        case idle
        case invalid
        case checking
        case available
        case unavailable(reason: String?)
        case error(String)
    }

    public private(set) var state: State = .idle { didSet { onChange?(state) } }
    public var onChange: ((State) -> Void)?

    private let client: LeaderboardClient
    private let guid: () -> String
    private let minimumInterval: TimeInterval
    private var currentText = ""
    private var queued: String?
    private var lastRequestAt = Date.distantPast
    private var worker: Task<Void, Never>?

    public init(client: LeaderboardClient, guid: @escaping () -> String, minimumInterval: TimeInterval = 1.0) {
        self.client = client
        self.guid = guid
        self.minimumInterval = minimumInterval
    }

    public func update(_ raw: String) {
        let name = LeaderboardName.normalize(raw)
        currentText = name
        guard !name.isEmpty else { queued = nil; state = .idle; return }
        guard LeaderboardName.isValid(name) else { queued = nil; state = .invalid; return }
        queued = name
        state = .checking
        if worker == nil {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while queued != nil {
            let wait = lastRequestAt.addingTimeInterval(minimumInterval).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let latest = queued else { break }
            queued = nil
            lastRequestAt = Date()
            let result: State
            do {
                let r = try await client.checkName(guid: guid(), name: latest)
                result = r.available ? .available : .unavailable(reason: r.reason)
            } catch {
                result = .error("Couldn't check the name right now")
            }
            if latest == currentText { state = result }
        }
        worker = nil
    }
}
