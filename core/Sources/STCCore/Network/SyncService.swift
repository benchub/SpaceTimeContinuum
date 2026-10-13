import Foundation

/// Uploads unsent minute rollups every 5 minutes ± 30 s while the leaderboard is enabled
/// and the computer is unlocked.
@MainActor
public final class SyncService {
    public static let interval: TimeInterval = 300
    public static let jitter: TimeInterval = 30

    private let store: ActivityStore
    private let client: LeaderboardClient
    private let settings: () -> AppSettings
    private let session: SessionStateProviding
    private var loop: Task<Void, Never>?
    private var notBefore = Date.distantPast
    public private(set) var lastResult: String?

    public init(store: ActivityStore, client: LeaderboardClient, session: SessionStateProviding, settings: @escaping () -> AppSettings) {
        self.store = store
        self.client = client
        self.session = session
        self.settings = settings
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let delay = Self.interval + Double.random(in: -Self.jitter...Self.jitter)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.syncNow()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public var isActive: Bool {
        Features.leaderboardAvailable && settings().leaderboardEnabled && session.isUnlocked
    }

    /// Uploads all pending rows in batches. Returns the number of rows marked uploaded.
    @discardableResult
    public func syncNow(now: Date = Date()) async -> Int {
        guard isActive, now >= notBefore else { return 0 }
        let s = settings()
        var marked = 0
        while true {
            let batch: [MinuteRollup]
            do { batch = try store.unuploadedMinutes(limit: LeaderboardClient.maxSamplesPerRequest) } catch { break }
            guard !batch.isEmpty else { break }
            do {
                let r = try await client.upload(
                    guid: s.deviceGUID, token: s.deviceToken, samples: batch,
                    utcOffsetSeconds: TimeZone.current.secondsFromGMT()
                )
                let done = r.accepted + Array(r.rejected.keys)
                try store.markUploaded(done)
                marked += done.count
                lastResult = "Uploaded \(r.accepted.count) minutes"
                if done.isEmpty || batch.count < LeaderboardClient.maxSamplesPerRequest { break }
            } catch LeaderboardClient.ClientError.http(let status, let message, let retryAfter) {
                if let retryAfter { notBefore = Date().addingTimeInterval(retryAfter) }
                lastResult = "Upload failed (\(status)): \(message ?? "")"
                break
            } catch {
                lastResult = "Upload failed: \(error.localizedDescription)"
                break
            }
        }
        return marked
    }
}

/// Downloads silly units from `/units` (New Entropy) and caches them on disk.
public struct UnitsUpdater: Sendable {
    public static let checkInterval: TimeInterval = 86400

    public let client: LeaderboardClient
    public let cacheURL: URL

    public init(client: LeaderboardClient, cacheURL: URL) {
        self.client = client
        self.cacheURL = cacheURL
    }

    public enum Outcome: Equatable, Sendable {
        case notModified
        case updated(UnitCatalog, etag: String?)
        case invalid
        case failed(String)
    }

    public func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= Self.checkInterval
    }

    public func loadCached() -> UnitCatalog? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? UnitCatalog(data: data)
    }

    public func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    public func fetch(etag: String?) async -> Outcome {
        do {
            switch try await client.fetchUnits(etag: loadCached() == nil ? nil : etag) {
            case .notModified:
                return .notModified
            case .updated(let data, let newETag):
                guard let catalog = try? UnitCatalog(data: data) else { return .invalid }
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
                return .updated(catalog, etag: newETag)
            }
        } catch {
            return .failed(String(describing: error))
        }
    }
}
