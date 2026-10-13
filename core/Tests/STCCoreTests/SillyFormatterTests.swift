import XCTest
@testable import STCCore

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class SillyFormatterTests: XCTestCase {
    let catalog = UnitCatalog(
        time: [SillyUnit(60, "minute"), SillyUnit(3300, "apple pie baking time"), SillyUnit(25200, "New York to London flight")],
        space: [
            SillyUnit(0.00007, "human hair width"), SillyUnit(0.01905, "penny diameter"), SillyUnit(1.8288, "fathom"),
            SillyUnit(443, "the Empire State Building"), SillyUnit(0.25, "cup of coffee", plural: "cups of coffee"),
        ]
    )

    func testPrefersHigherMultipleOfSmallerUnit() {
        var rng = SeededRNG(state: 1)
        let f = SillyFormatter(catalog: catalog)
        // 8 m: penny gives 420 (too many), fathom gives 4.4, cup gives 32 → cup (tier 10–200).
        let c = f.choose(8, .space, using: &rng)!
        XCTAssertEqual(c.unit.label, "cup of coffee")
        XCTAssertEqual(c.text, "exactly 32 cups of coffee")
        XCTAssertEqual(f.choose(8.1, .space, using: &rng)!.text, "about 32 cups of coffee")
    }

    func testRoundingAndExactly() {
        var rng = SeededRNG(state: 2)
        let f = SillyFormatter(catalog: catalog)
        XCTAssertEqual(f.choose(0.014, .space, using: &rng)?.text, "exactly 200 human hair widths")
        XCTAssertEqual(f.choose(886, .space, using: &rng)?.text, "exactly 2 Empire State Buildings")
        XCTAssertEqual(f.format(0, .time, using: &rng), "not even a blink")
        XCTAssertEqual(f.choose(443, .space, using: &rng)?.text, "exactly 1 Empire State Building")
    }

    func testMultipleStaysWithinBoundsWhenPossible() {
        var rng = SeededRNG(state: 3)
        let f = SillyFormatter(catalog: catalog)
        for v in stride(from: 61.0, to: 4_000_000, by: 997) {
            let c = f.choose(v, .time, using: &rng)!
            XCTAssertLessThanOrEqual(c.displayedMultiple, 200, "\(v) → \(c.text)")
        }
    }

    func testPluralization() {
        XCTAssertEqual(SillyFormatter.pluralWord("bus"), "buses")
        XCTAssertEqual(SillyFormatter.pluralWord("body"), "bodies")
        XCTAssertEqual(SillyFormatter.pluralWord("day"), "days")
        XCTAssertEqual(SillyFormatter.pluralWord("foot"), "feet")
        XCTAssertEqual(SillyFormatter.pluralWord("Sheep"), "Sheep")
        XCTAssertEqual(SillyFormatter.pluralWord("potato"), "potatoes")
        XCTAssertEqual(SillyFormatter.pluralWord("piano"), "pianos")
        XCTAssertEqual(SillyFormatter.pluralize(SillyUnit(1, "a giraffe")), "giraffes")
    }

    func testNumberFormatting() {
        XCTAssertEqual(SillyFormatter.numberString(2.5), "2.5")
        XCTAssertEqual(SillyFormatter.numberString(0.25), "0.25")
        XCTAssertEqual(SillyFormatter.numberString(140), "140")
        XCTAssertEqual(SillyFormatter.numberString(12345), "12,345")
        XCTAssertEqual(SillyFormatter.rounded(2.04), 2)
        XCTAssertEqual(SillyFormatter.rounded(0.123), 0.12)
    }

    func testCatalogParsingAndValidation() throws {
        let entries = (1...12).map { "[\($0), \"thing \($0)\"]" }.joined(separator: ",")
        let good = "{\"time\": [\(entries), [5, \"cup of tea\", \"cups of tea\"], [-1, \"bad\"], [3, \"\"]], \"space\": [\(entries)], \"extra\": 1}"
        let c = try UnitCatalog(data: Data(good.utf8))
        XCTAssertEqual(c.time.count, 13)
        XCTAssertEqual(c.time.first(where: { $0.label == "cup of tea" })?.plural, "cups of tea")

        let few = "{\"time\": [[1, \"a\"]], \"space\": [\(entries)]}"
        XCTAssertThrowsError(try UnitCatalog(data: Data(few.utf8)))
        XCTAssertThrowsError(try UnitCatalog(data: Data("nope".utf8)))
    }

    func testBundledCatalogsLoadAndCover() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared")
        let units = try UnitCatalog(data: Data(contentsOf: shared.appendingPathComponent("units.json")))
        XCTAssertGreaterThanOrEqual(units.time.count, 300)
        XCTAssertGreaterThanOrEqual(units.space.count, 300)
        var rng = SeededRNG(state: 9)
        let f = SillyFormatter(catalog: units)
        for (v, kind) in [(30.0, MeasureKind.time), (3600, .time), (86400 * 20, .time), (0.01, .space), (8, .space), (1_500_000, .space)] {
            let c = try XCTUnwrap(f.choose(v, kind, using: &rng))
            XCTAssertTrue((1...200).contains(c.displayedMultiple), "\(v) → \(c.text)")
        }

        let keyboards = try KeyboardCatalog(data: Data(contentsOf: shared.appendingPathComponent("keyboards.json")))
        let advantage = KeyboardDevice(vendorID: 10730, productID: 258, productName: "Advantage2 Keyboard", isBuiltIn: false)
        XCTAssertEqual(keyboards.suggestion(for: advantage).travelMM, 4.1)
    }
}

final class KeyboardCatalogTests: XCTestCase {
    func testMatchingAndDefaults() {
        let catalog = KeyboardCatalog(entries: [
            .init(name: "Kinesis Advantage2", vendorID: 10730, namePatterns: ["advantage2"], travelMM: 4.1),
            .init(name: "Keychron (generic)", vendorID: 13364, namePatterns: [], travelMM: 4.0),
        ])
        let builtIn = KeyboardDevice(vendorID: 1452, productID: 832, productName: "Apple Internal Keyboard / Trackpad", isBuiltIn: true)
        let kinesis = KeyboardDevice(vendorID: 10730, productID: 258, productName: "Advantage2 Keyboard", isBuiltIn: false)
        let keychron = KeyboardDevice(vendorID: 13364, productID: 1, productName: "Keychron Q1", isBuiltIn: false)
        let mystery = KeyboardDevice(vendorID: 1, productID: 1, productName: "USB Keyboard", isBuiltIn: false)

        XCTAssertEqual(catalog.suggestion(for: kinesis), .init(travelMM: 4.1, source: .database(name: "Kinesis Advantage2")))
        XCTAssertEqual(catalog.suggestion(for: keychron).travelMM, 4.0)
        XCTAssertEqual(catalog.suggestion(for: builtIn).source, .builtInDefault)
        XCTAssertEqual(catalog.suggestion(for: mystery).source, .unknownDefault)
        XCTAssertEqual(KeyboardCatalog.primary(of: [builtIn, kinesis]), kinesis)
        XCTAssertEqual(KeyboardCatalog.primary(of: [builtIn]), builtIn)

        var settings = AppSettings()
        XCTAssertEqual(settings.travelMM(for: kinesis, catalog: catalog), 4.1)
        settings.keyboardTravelMM[kinesis.id] = 3.5
        XCTAssertEqual(settings.travelMM(for: kinesis, catalog: catalog), 3.5)
    }
}
