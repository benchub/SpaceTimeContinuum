import Foundation

/// Converts seconds and meters into absurd-but-true phrases like
/// "about 140 human hair widths" or "about 2.5 New York to London flights".
public struct SillyFormatter: Sendable {
    public var catalog: UnitCatalog

    public init(catalog: UnitCatalog) {
        self.catalog = catalog
    }

    public struct Choice: Equatable, Sendable {
        public var unit: SillyUnit
        /// value / unit.value, unrounded.
        public var multiple: Double
        /// The multiple as displayed.
        public var displayedMultiple: Double
        public var isExact: Bool
        public var text: String
    }

    public func format(_ value: Double, _ kind: MeasureKind) -> String {
        var rng = SystemRandomNumberGenerator()
        return format(value, kind, using: &rng)
    }

    public func format<R: RandomNumberGenerator>(_ value: Double, _ kind: MeasureKind, using rng: inout R) -> String {
        choose(value, kind, using: &rng)?.text ?? Self.nothingPhrase(kind)
    }

    /// Picks a unit:
    /// 1. Prefer units giving a multiple in 10...200 (higher multiples of smaller things).
    /// 2. Otherwise 1..<10, then 0.01..<1.
    /// 3. Otherwise whichever unit is closest (in log terms) to a multiple of 100.
    /// Ties within a tier are broken randomly.
    public func choose<R: RandomNumberGenerator>(_ value: Double, _ kind: MeasureKind, using rng: inout R) -> Choice? {
        guard value > 0, value.isFinite else { return nil }
        let units = catalog.units(kind)
        guard !units.isEmpty else { return nil }

        let tiers: [ClosedRange<Double>] = [10...200, 1...9.9999999, 0.01...0.9999999]
        for tier in tiers {
            let candidates = units.filter { tier.contains(Self.rounded(value / $0.value)) }
            if let unit = candidates.randomElement(using: &rng) {
                return makeChoice(value, unit)
            }
        }
        let closest = units.min { abs(log(value / $0.value) - log(100)) < abs(log(value / $1.value) - log(100)) }!
        return makeChoice(value, closest)
    }

    private func makeChoice(_ value: Double, _ unit: SillyUnit) -> Choice {
        let multiple = value / unit.value
        let shown = Self.rounded(multiple)
        let exact = abs(shown - multiple) <= multiple * 1e-9
        let number = Self.numberString(shown)
        let noun = shown == 1 ? Self.stripArticle(unit.label) : Self.pluralize(unit)
        let text = "\(exact ? "exactly" : "about") \(number) \(noun)"
        return Choice(unit: unit, multiple: multiple, displayedMultiple: shown, isExact: exact, text: text)
    }

    /// 20 and up: whole numbers; 1–20: one decimal; below 1: two decimals.
    static func rounded(_ m: Double) -> Double {
        if m >= 19.95 { return m.rounded() }
        if m >= 0.995 { return (m * 10).rounded() / 10 }
        return (m * 100).rounded() / 100
    }

    static func numberString(_ m: Double) -> String {
        if m >= 1000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            f.locale = Locale(identifier: "en_US")
            return f.string(from: NSNumber(value: m)) ?? String(Int(m))
        }
        if m == m.rounded() { return String(Int(m)) }
        var s = String(format: m < 1 ? "%.2f" : "%.1f", m)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }

    static func nothingPhrase(_ kind: MeasureKind) -> String {
        kind == .time ? "not even a blink" : "not even a smidge"
    }

    static func stripArticle(_ label: String) -> String {
        for article in ["a ", "an ", "the "] where label.lowercased().hasPrefix(article) {
            return String(label.dropFirst(article.count))
        }
        return label
    }

    static func pluralize(_ unit: SillyUnit) -> String {
        if let p = unit.plural { return stripArticle(p) }
        let label = stripArticle(unit.label)
        guard let range = label.range(of: "[A-Za-z]+$", options: .regularExpression) else { return label }
        let word = String(label[range])
        return label.replacingCharacters(in: range, with: pluralWord(word))
    }

    private static let irregular: [String: String] = [
        "foot": "feet", "tooth": "teeth", "mouse": "mice", "person": "people", "child": "children",
        "man": "men", "woman": "women", "leaf": "leaves", "knife": "knives", "life": "lives",
        "loaf": "loaves", "half": "halves", "goose": "geese", "ox": "oxen", "wolf": "wolves",
        "shelf": "shelves", "calf": "calves", "elf": "elves", "die": "dice", "louse": "lice",
    ]
    private static let invariant: Set<String> = [
        "sheep", "deer", "fish", "series", "species", "aircraft", "moose", "bison", "salmon",
        "trout", "spacecraft", "offspring", "swine", "headquarters", "means", "news",
    ]
    private static let oEs: Set<String> = ["potato", "tomato", "hero", "echo", "torpedo", "volcano", "veto", "mosquito"]

    static func pluralWord(_ word: String) -> String {
        let lower = word.lowercased()
        let isUpper = word == word.uppercased() && word.count > 1
        func cased(_ s: String) -> String {
            if isUpper { return s.uppercased() }
            if word.first?.isUppercase == true { return s.prefix(1).uppercased() + s.dropFirst() }
            return s
        }
        if isUpper { return word + "s" } // acronyms: "NBA game" handled by last word; "ISS" → "ISSs"
        if invariant.contains(lower) { return word }
        if let irr = irregular[lower] { return cased(irr) }
        if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("z")
            || lower.hasSuffix("ch") || lower.hasSuffix("sh") {
            return word + "es"
        }
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) {
            return String(word.dropLast()) + "ies"
        }
        if oEs.contains(lower) { return word + "es" }
        return word + "s"
    }
}

/// Plain, non-silly formatting used in tooltips and graph axes.
public enum RealUnits {
    public static func distance(_ meters: Double) -> String {
        let m = max(0, meters)
        if m >= 1000 { return String(format: "%.2f km", m / 1000) }
        if m >= 1 { return String(format: "%.1f m", m) }
        if m >= 0.01 { return String(format: "%.1f cm", m * 100) }
        return String(format: "%.1f mm", m * 1000)
    }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}

/// Small deterministic RNG so a given value can map to the same silly unit every time
/// (e.g. while hovering over a graph), instead of re-rolling on each redraw.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public init(_ value: Double, salt: Int = 0) {
        self.init(seed: value.bitPattern ^ UInt64(bitPattern: Int64(salt)))
    }

    public mutating func next() -> UInt64 {
        // SplitMix64
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
