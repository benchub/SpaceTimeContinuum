import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app version, shared by every platform. Must match `CFBundleShortVersionString` in
/// macos/Resources/Info.plist (a test checks), since Sparkle reads that one.
public enum AppVersion {
    public static let current = "0.4.1"

    /// Compares dotted numeric versions ("0.10.0" > "0.9.2"). Missing parts count as 0.
    public static func isNewer(_ candidate: String, than base: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(candidate), b = parts(base)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Finds out whether a newer release exists, from the Sparkle appcast the Mac app updates from.
/// Platforms without Sparkle use this to tell people an update is available.
public struct UpdateChecker: Sendable {
    public static let appcastURL = URL(string: "https://spacetime.silentmedia.com/updates/appcast.xml")!
    public static let checkInterval: TimeInterval = 86400

    public let client: LeaderboardClient

    public init(client: LeaderboardClient) {
        self.client = client
    }

    public func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= Self.checkInterval
    }

    /// The newest version in the appcast, or nil if it couldn't be read.
    public func latestVersion() async throws -> String? {
        var req = URLRequest(url: Self.appcastURL)
        req.timeoutInterval = 30
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.transport.send(req)
        guard response.statusCode == 200 else { throw LeaderboardClient.ClientError.http(status: response.statusCode, message: nil, retryAfter: nil) }
        return Self.newestVersion(inAppcast: String(decoding: data, as: UTF8.self))
    }

    /// The highest `sparkle:shortVersionString` in an appcast. A regex rather than XMLParser,
    /// which on Linux would drag libxml2 into static builds.
    public static func newestVersion(inAppcast xml: String) -> String? {
        let pattern = #"<sparkle:shortVersionString>\s*([0-9][0-9A-Za-z.\-]*)\s*</sparkle:shortVersionString>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(xml.startIndex..., in: xml)
        let versions = regex.matches(in: xml, range: range).compactMap { match in
            Range(match.range(at: 1), in: xml).map { String(xml[$0]) }
        }
        return versions.max { AppVersion.isNewer($1, than: $0) }
    }
}
