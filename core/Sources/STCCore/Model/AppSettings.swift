import Foundation

/// Feature switches for functionality that exists in code but isn't offered to users yet.
public enum Features {
    /// The leaderboard server is live; joining is still opt-in (`AppSettings.leaderboardEnabled` defaults to false).
    public static var leaderboardAvailable = true
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
    public var nannyRules = NannyRules()
    public var mistressEnabled: Bool = false
    public var mistressRules = MistressRules()
    public var newEntropyEnabled: Bool = true
    public var launchAtLogin: Bool = true
    public var unitsETag: String?
    public var unitsLastChecked: Date?
    public var lastNagAt: Date?

    public init(deviceGUID: String = UUID().uuidString.lowercased(), deviceToken: String = AppSettings.makeToken()) {
        self.deviceGUID = deviceGUID
        self.deviceToken = deviceToken
    }

    /// Tolerates saved settings that predate newer fields, so an upgrade never loses the device identity.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceGUID = try c.decode(String.self, forKey: .deviceGUID)
        deviceToken = try c.decode(String.self, forKey: .deviceToken)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? configured
        keyboardTravelMM = try c.decodeIfPresent([String: Double].self, forKey: .keyboardTravelMM) ?? keyboardTravelMM
        fallbackTravelMM = try c.decodeIfPresent(Double.self, forKey: .fallbackTravelMM) ?? fallbackTravelMM
        leaderboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .leaderboardEnabled) ?? leaderboardEnabled
        leaderboardName = try c.decodeIfPresent(String.self, forKey: .leaderboardName) ?? leaderboardName
        nannyEnabled = try c.decodeIfPresent(Bool.self, forKey: .nannyEnabled) ?? nannyEnabled
        nannyRules = (try? c.decodeIfPresent(NannyRules.self, forKey: .nannyRules)) ?? nannyRules
        mistressEnabled = try c.decodeIfPresent(Bool.self, forKey: .mistressEnabled) ?? mistressEnabled
        mistressRules = (try? c.decodeIfPresent(MistressRules.self, forKey: .mistressRules)) ?? mistressRules
        newEntropyEnabled = try c.decodeIfPresent(Bool.self, forKey: .newEntropyEnabled) ?? newEntropyEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        unitsETag = try c.decodeIfPresent(String.self, forKey: .unitsETag)
        unitsLastChecked = try c.decodeIfPresent(Date.self, forKey: .unitsLastChecked)
        lastNagAt = try c.decodeIfPresent(Date.self, forKey: .lastNagAt)
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
