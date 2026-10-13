import Foundation

public enum MeasureKind: String, Sendable, CaseIterable {
    /// Seconds.
    case time
    /// Meters.
    case space
}

public struct SillyUnit: Equatable, Sendable {
    /// Seconds (time) or meters (space) in one of this thing.
    public var value: Double
    public var label: String
    public var plural: String?

    public init(_ value: Double, _ label: String, plural: String? = nil) {
        self.value = value
        self.label = label
        self.plural = plural
    }
}

/// The list of silly units, from the bundled `units.json` or downloaded via New Entropy.
public struct UnitCatalog: Equatable, Sendable {
    public var time: [SillyUnit]
    public var space: [SillyUnit]

    public static let minimumEntries = 10
    public static let maximumLabelLength = 120

    public enum ValidationError: Error, Equatable {
        case notJSON
        case tooFewEntries(kind: String, count: Int)
    }

    public init(time: [SillyUnit], space: [SillyUnit]) {
        self.time = time.sorted { $0.value < $1.value }
        self.space = space.sorted { $0.value < $1.value }
    }

    /// Parses and validates the documented JSON format. Invalid entries are skipped; the
    /// whole document is rejected if fewer than `minimumEntries` valid entries remain per kind.
    public init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError.notJSON
        }
        func parse(_ key: String) throws -> [SillyUnit] {
            let raw = root[key] as? [Any] ?? []
            var seen = Set<String>()
            let units: [SillyUnit] = raw.compactMap { item in
                guard let arr = item as? [Any], arr.count == 2 || arr.count == 3,
                      let num = arr[0] as? NSNumber,
                      let label = (arr[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return nil }
                let v = num.doubleValue
                guard v.isFinite, v > 0, !label.isEmpty, label.count <= Self.maximumLabelLength else { return nil }
                var plural: String?
                if arr.count == 3 {
                    guard let p = (arr[2] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !p.isEmpty, p.count <= Self.maximumLabelLength else { return nil }
                    plural = p
                }
                guard seen.insert(label.lowercased()).inserted else { return nil }
                return SillyUnit(v, label, plural: plural)
            }
            guard units.count >= Self.minimumEntries else {
                throw ValidationError.tooFewEntries(kind: key, count: units.count)
            }
            return units
        }
        self.init(time: try parse("time"), space: try parse("space"))
    }

    public func units(_ kind: MeasureKind) -> [SillyUnit] {
        kind == .time ? time : space
    }
}
