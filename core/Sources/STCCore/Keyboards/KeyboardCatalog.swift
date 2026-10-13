import Foundation

/// Key-travel database loaded from `shared/keyboards.json`.
public struct KeyboardCatalog: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var vendorID: Int?
        public var productIDs: [Int]?
        public var namePatterns: [String]
        public var travelMM: Double
        public var switchType: String?

        enum CodingKeys: String, CodingKey {
            case name
            case vendorID = "vendor_id"
            case productIDs = "product_ids"
            case namePatterns = "name_patterns"
            case travelMM = "travel_mm"
            case switchType = "switch"
        }

        public init(name: String, vendorID: Int? = nil, productIDs: [Int]? = nil, namePatterns: [String], travelMM: Double, switchType: String? = nil) {
            self.name = name
            self.vendorID = vendorID
            self.productIDs = productIDs
            self.namePatterns = namePatterns
            self.travelMM = travelMM
            self.switchType = switchType
        }

        func matches(_ k: KeyboardDevice) -> Bool {
            if let vendorID, vendorID != k.vendorID { return false }
            if let productIDs, !productIDs.contains(k.productID) { return false }
            let name = k.productName.lowercased()
            if namePatterns.isEmpty && vendorID == nil && productIDs == nil { return false }
            return namePatterns.allSatisfy { name.contains($0.lowercased()) }
        }
    }

    public struct Defaults: Codable, Sendable, Equatable {
        public var builtinLaptopMM: Double
        public var mechanicalMM: Double
        public var unknownExternalMM: Double

        enum CodingKeys: String, CodingKey {
            case builtinLaptopMM = "builtin_laptop_mm"
            case mechanicalMM = "mechanical_mm"
            case unknownExternalMM = "unknown_external_mm"
        }

        public init(builtinLaptopMM: Double = 1.0, mechanicalMM: Double = 3.0, unknownExternalMM: Double = 2.0) {
            self.builtinLaptopMM = builtinLaptopMM
            self.mechanicalMM = mechanicalMM
            self.unknownExternalMM = unknownExternalMM
        }
    }

    public enum Source: Equatable, Sendable {
        case database(name: String)
        case builtInDefault
        case unknownDefault
    }

    public struct Suggestion: Equatable, Sendable {
        public var travelMM: Double
        public var source: Source
    }

    public var defaults: Defaults
    public var entries: [Entry]

    public init(defaults: Defaults = Defaults(), entries: [Entry] = []) {
        self.defaults = defaults
        self.entries = entries
    }

    public init(data: Data) throws {
        struct File: Codable {
            var defaults: Defaults?
            var keyboards: [Entry]
        }
        let f = try JSONDecoder().decode(File.self, from: data)
        self.init(defaults: f.defaults ?? Defaults(), entries: f.keyboards.filter { $0.travelMM > 0 && $0.travelMM < 20 })
    }

    public func suggestion(for keyboard: KeyboardDevice) -> Suggestion {
        if let e = entries.first(where: { $0.matches(keyboard) }) {
            return Suggestion(travelMM: e.travelMM, source: .database(name: e.name))
        }
        if keyboard.isBuiltIn {
            return Suggestion(travelMM: defaults.builtinLaptopMM, source: .builtInDefault)
        }
        return Suggestion(travelMM: defaults.unknownExternalMM, source: .unknownDefault)
    }

    /// The keyboard most likely to be typed on: an external one if attached, else the built-in.
    public static func primary(of keyboards: [KeyboardDevice]) -> KeyboardDevice? {
        keyboards.first(where: { !$0.isBuiltIn }) ?? keyboards.first
    }
}
