import Foundation

/// Feature switches for functionality that exists in code but isn't offered to users yet.
public enum Features {
    /// The leaderboard server isn't live yet: the checkbox, name check and sync stay disabled.
    public static var leaderboardAvailable = false
}

/// User preferences and identity, persisted as JSON in the `settings` table.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Public identifier used by the leaderboard.
    public var deviceGUID: String
    /// Secret sent as `X-STC-Token`; never shown to the user.
    public var deviceToken: String
    /// True once the user has closed the first-run Configuration screen.
    public var configured: Bool = false
    /// Key travel in millimetres, keyed by `KeyboardDevice.id`.
    public var keyboardTravelMM: [String: Double] = [:]
    /// Travel used for key presses from keyboards with no explicit setting.
    public var fallbackTravelMM: Double = 1.0
    public var leaderboardEnabled: Bool = false
    public var leaderboardName: String = ""
    public var nannyEnabled: Bool = false
    public var newEntropyEnabled: Bool = true
    public var launchAtLogin: Bool = true
    public var unitsETag: String?
    public var unitsLastChecked: Date?
    public var lastNagAt: Date?

    public init(deviceGUID: String = UUID().uuidString.lowercased(), deviceToken: String = AppSettings.makeToken()) {
        self.deviceGUID = deviceGUID
        self.deviceToken = deviceToken
    }

    /// 32 random bytes as 64 lowercase hex characters.
    public static func makeToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    /// New identity (GUID + token), as done by "reset tracking history".
    public mutating func regenerateIdentity() {
        deviceGUID = UUID().uuidString.lowercased()
        deviceToken = Self.makeToken()
        leaderboardName = ""
        leaderboardEnabled = false
    }

    public func travelMM(for keyboard: KeyboardDevice, catalog: KeyboardCatalog) -> Double {
        keyboardTravelMM[keyboard.id] ?? catalog.suggestion(for: keyboard).travelMM
    }
}

extension ActivityStore {
    private static let settingsKey = "app_settings"

    /// Loads settings, creating (and saving) defaults with a fresh identity on first run.
    public func loadSettings() throws -> AppSettings {
        if let json = try setting(Self.settingsKey),
           let data = json.data(using: .utf8),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return s
        }
        let s = AppSettings()
        try saveSettings(s)
        return s
    }

    public func saveSettings(_ settings: AppSettings) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(settings)
        try setSetting(Self.settingsKey, String(decoding: data, as: UTF8.self))
    }
}
