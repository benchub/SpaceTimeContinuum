import AppKit
import CoreGraphics
import IOKit
import IOKit.hid
import STCCore

/// Watches keyboards via IOHIDManager (so we know *which* keyboard each press came from)
/// and pointer movement via a listen-only CGEventTap.
///
/// Both require the "Input Monitoring" privacy permission. Callbacks arrive on the main run loop.
final class MacInputMonitor: InputMonitoring {
    /// A key went down: which keyboard, and its HID usage (page 0x07). Also fires while the
    /// keyboard is blocked, since IOHID sits below the blocking event tap.
    var onKeyPress: ((KeyboardDevice, UInt32) -> Void)?
    var onPointerMove: ((Double) -> Void)?
    var onKeyboardsChanged: (() -> Void)?

    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice: KeyboardDevice] = [:]
    private var ignoredDevices = Set<IOHIDDevice>()
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var odometer = PointerOdometer()
    private var screenObserver: NSObjectProtocol?

    var keyboards: [KeyboardDevice] {
        var seen = Set<String>()
        return devices.values
            .sorted { ($0.isBuiltIn ? 1 : 0, $0.productName) < ($1.isBuiltIn ? 1 : 0, $1.productName) }
            .filter { seen.insert($0.id).inserted }
    }

    var hasPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func requestPermission() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() throws {
        refreshDisplays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshDisplays() }
        startKeyboards()
        startPointer()
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        devices.removeAll()
        ignoredDevices.removeAll()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        eventTap = nil
        tapSource = nil
        if let fallbackMonitor { NSEvent.removeMonitor(fallbackMonitor) }
        fallbackMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Restart after permission is granted.
    func restart() {
        stop()
        try? start()
    }

    /// Forget the last pointer position (e.g. after sleep).
    func resetPointer() { odometer.reset() }

    // MARK: Keyboards

    private func startKeyboards() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<MacInputMonitor>.fromOpaque(ctx).takeUnretainedValue().deviceAdded(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<MacInputMonitor>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<MacInputMonitor>.fromOpaque(ctx).takeUnretainedValue().inputValue(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        func prop<T>(_ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }
        let name: String = prop(kIOHIDProductKey) ?? "Unknown keyboard"
        if KeyboardDevice.isIgnored(productName: name, manufacturer: prop(kIOHIDManufacturerKey)) {
            ignoredDevices.insert(device)
            return
        }
        let transport: String = prop(kIOHIDTransportKey) ?? ""
        let builtIn = (prop(kIOHIDBuiltInKey) as Bool?) ?? false
            || ["SPI", "FIFO"].contains(transport)
            || name.localizedCaseInsensitiveContains("internal")
        devices[device] = KeyboardDevice(
            vendorID: prop(kIOHIDVendorIDKey) ?? 0,
            productID: prop(kIOHIDProductIDKey) ?? 0,
            productName: name,
            manufacturer: prop(kIOHIDManufacturerKey),
            isBuiltIn: builtIn
        )
        onKeyboardsChanged?()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        ignoredDevices.remove(device)
        devices[device] = nil
        onKeyboardsChanged?()
    }

    private func inputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        let usage = IOHIDElementGetUsage(element)
        // 0x04... are real keys (0x00–0x03 are error/rollover codes); 0xE0–0xE7 are modifiers.
        guard (0x04...0xE7).contains(usage), IOHIDValueGetIntegerValue(value) == 1 else { return }
        let device = IOHIDElementGetDevice(element)
        if ignoredDevices.contains(device) { return }
        let keyboard = devices[device] ?? KeyboardDevice(vendorID: 0, productID: 0, productName: "Unknown keyboard", isBuiltIn: false)
        onKeyPress?(keyboard, usage)
    }

    // MARK: Pointer

    private func startPointer() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                guard let ctx else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MacInputMonitor>.fromOpaque(ctx).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    monitor.pointerMoved(
                        to: event.location,
                        raw: CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
                    )
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        )
        if let tap {
            eventTap = tap
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            // Global mouse-move monitors don't need extra permission; locations are in Cocoa
            // coordinates (origin bottom-left), so flip them into CG global coordinates.
            fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
                let p = NSEvent.mouseLocation
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                self?.pointerMoved(to: CGPoint(x: p.x, y: primaryHeight - p.y), raw: CGVector(dx: event.deltaX, dy: event.deltaY))
            }
        }
    }

    private func pointerMoved(to point: CGPoint, raw: CGVector) {
        let meters = odometer.move(to: point, rawDelta: raw)
        if meters > 0 { onPointerMove?(meters) }
    }

    private func refreshDisplays() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)
        odometer.displays = ids.prefix(Int(count)).map { id in
            DisplayGeometry(id: id, bounds: CGDisplayBounds(id), physicalSizeMM: CGDisplayScreenSize(id))
        }
        odometer.reset()
    }
}
