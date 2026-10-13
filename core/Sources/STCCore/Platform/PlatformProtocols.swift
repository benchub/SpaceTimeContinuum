import Foundation

// Interfaces each platform shell (macOS, and later Linux/Windows) implements.

/// Reports whether any display is on and whether the user session is unlocked.
public protocol SessionStateProviding: AnyObject {
    var isScreenOn: Bool { get }
    var isUnlocked: Bool { get }
}

/// A physical (or virtual) keyboard attached to the computer.
public struct KeyboardDevice: Hashable, Codable, Sendable, Identifiable {
    public var vendorID: Int
    public var productID: Int
    public var productName: String
    public var manufacturer: String?
    public var isBuiltIn: Bool

    public init(vendorID: Int, productID: Int, productName: String, manufacturer: String? = nil, isBuiltIn: Bool) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.manufacturer = manufacturer
        self.isBuiltIn = isBuiltIn
    }

    /// Stable key used to remember per-keyboard travel settings.
    public var id: String { "\(vendorID):\(productID):\(productName)" }
}

/// Watches keyboards and the pointer and feeds a `Recorder`.
public protocol InputMonitoring: AnyObject {
    /// Keyboards currently attached.
    var keyboards: [KeyboardDevice] { get }
    /// Whether the OS has granted permission to observe input.
    var hasPermission: Bool { get }
    func requestPermission()
    func start() throws
    func stop()
}

/// Registers the app to start when the user logs in.
public protocol LoginItemManaging: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Shows a user notification.
public protocol Notifying: AnyObject {
    func requestAuthorization()
    func notify(title: String, body: String)
}
