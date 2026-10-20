import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import STCCore

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(AppVersion.isNewer("0.4.2", than: "0.4.1"))
        XCTAssertTrue(AppVersion.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(AppVersion.isNewer("1.0", than: "0.99.99"))
        XCTAssertFalse(AppVersion.isNewer("0.4.1", than: "0.4.1"))
        XCTAssertFalse(AppVersion.isNewer("0.4", than: "0.4.0"))
        XCTAssertFalse(AppVersion.isNewer("0.4.0", than: "0.4.1"))
    }

    func testNewestVersionInAppcast() {
        let xml = """
            <rss><channel>
            <item><sparkle:shortVersionString>0.4.0</sparkle:shortVersionString></item>
            <item><sparkle:shortVersionString> 0.10.1 </sparkle:shortVersionString></item>
            <item><sparkle:shortVersionString>0.9.0</sparkle:shortVersionString></item>
            </channel></rss>
            """
        XCTAssertEqual(UpdateChecker.newestVersion(inAppcast: xml), "0.10.1")
        XCTAssertNil(UpdateChecker.newestVersion(inAppcast: "<rss></rss>"))
    }

    func testLatestVersionFetch() async throws {
        let client = LeaderboardClient(transport: StubTransport { req in
            XCTAssertEqual(req.url, UpdateChecker.appcastURL)
            return (200, [:], "<item><sparkle:shortVersionString>9.9.9</sparkle:shortVersionString></item>")
        }, userAgent: "test")
        let latest = try await UpdateChecker(client: client).latestVersion()
        XCTAssertEqual(latest, "9.9.9")
    }

    /// Sparkle reads the Mac version from Info.plist; the shared constant must agree.
    func testVersionMatchesMacInfoPlist() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("macos/Resources/Info.plist")
        let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        XCTAssertEqual(dict?["CFBundleShortVersionString"] as? String, AppVersion.current,
                       "Bump AppVersion.current in core/Sources/STCCore/Network/UpdateChecker.swift along with Info.plist")
    }
}
