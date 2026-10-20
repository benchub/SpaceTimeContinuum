import AppKit
import ApplicationServices
import CoreGraphics
import STCCore

/// Swallows keyboard and/or pointer events with an active event tap while a lockout is running.
///
/// Creating an active tap needs the Accessibility permission. The tap exists only during a lockout.
/// Key presses still reach IOHID (and so the safe word check) while the keyboard is blocked.
final class MacInputBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var devices: Set<InputDevice> = []
    private var cursorFrozen = false
    private var frozenLocation = CGPoint.zero

    private static let keyboardTypes: Set<CGEventType> = [
        .keyDown, .keyUp, .flagsChanged, CGEventType(rawValue: 14)!, // 14 = media/system keys
    ]
    private static let pointerButtonTypes: Set<CGEventType> = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt if the permission is missing.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    var isBlocking: Bool { tap != nil }

    /// Starts blocking `devices`; a blocked pointer is frozen in place.
    /// Returns false if the tap couldn't be created (no Accessibility permission).
    @discardableResult
    func block(_ devices: Set<InputDevice>) -> Bool {
        unblock()
        guard !devices.isEmpty else { return true }
        self.devices = devices

        let types = Self.keyboardTypes.union(Self.pointerButtonTypes).union([.mouseMoved])
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MacInputBlocker>.fromOpaque(ctx).takeUnretainedValue().handle(type, event)
            },
            userInfo: context
        ) else {
            self.devices = []
            return false
        }
        self.tap = tap
        if devices.contains(.pointer) {
            frozenLocation = CGEvent(source: nil)?.location ?? .zero
            // Also detach the cursor from the mouse; the warp in `handle` is the backstop.
            CGAssociateMouseAndMouseCursorPosition(0)
            cursorFrozen = true
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func unblock() {
        if cursorFrozen {
            CGAssociateMouseAndMouseCursorPosition(1)
            cursorFrozen = false
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        devices = []
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if Self.keyboardTypes.contains(type) { return devices.contains(.keyboard) ? nil : pass }
        guard devices.contains(.pointer) else { return pass }
        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            // Dropping the event isn't enough to stop the cursor, so pin it in place.
            CGWarpMouseCursorPosition(frozenLocation)
            return nil
        }
        return nil
    }
}
