#if canImport(Glibc)
import Glibc
#endif
import Foundation
import STCCore

/// Watches keyboards and pointers by reading `/dev/input/event*` directly (evdev).
///
/// Works the same under X11 and Wayland because it sits below both. Needs read access to the
/// device nodes, which normally means being in the `input` group. Each device gets its own
/// reader thread; callbacks are delivered on the main queue.
///
/// Mistress Mode blocks devices with `EVIOCGRAB`, which hands their events to us alone. We keep
/// reading grabbed devices (so the safe word works), and the kernel drops the grab if we die.
final class LinuxInputMonitor: InputMonitoring {
    /// A key went down: which keyboard, and the evdev key code. Also fires for grabbed keyboards.
    var onKeyPress: ((KeyboardDevice, Int) -> Void)?
    var onPointerMove: ((Double) -> Void)?
    var onKeyboardsChanged: (() -> Void)?

    /// Mouse resolution used to turn relative motion counts into distance. Linux can't tell us
    /// where the cursor is under Wayland, so this measures how far the mouse moved, not the cursor.
    var mouseDPI: Double = 1000

    private let lock = NSLock()
    private var open: [String: OpenDevice] = [:]
    private var rescanTimer: DispatchSourceTimer?
    private var grabRetry: DispatchSourceTimer?

    /// Devices to block. Grabs follow hot-plugged devices too. Main queue only.
    var blockedDevices: Set<InputDevice> = [] {
        didSet { applyGrabs() }
    }

    private final class OpenDevice {
        let path: String
        let fd: Int32
        let keyboard: KeyboardDevice?
        let isPointer: Bool
        let absScale: (x: Double, y: Double)?
        /// Main queue only.
        var grabbed = false
        init(path: String, fd: Int32, keyboard: KeyboardDevice?, isPointer: Bool, absScale: (x: Double, y: Double)?) {
            self.path = path
            self.fd = fd
            self.keyboard = keyboard
            self.isPointer = isPointer
            self.absScale = absScale
        }
    }

    var keyboards: [KeyboardDevice] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        return open.values.compactMap(\.keyboard)
            .sorted { ($0.isBuiltIn ? 1 : 0, $0.productName) < ($1.isBuiltIn ? 1 : 0, $1.productName) }
            .filter { seen.insert($0.id).inserted }
    }

    /// True if at least one input device node can be opened.
    var hasPermission: Bool {
        Self.eventNodes().contains { access($0, R_OK) == 0 }
    }

    func requestPermission() {
        let user = ProcessInfo.processInfo.environment["USER"] ?? "$USER"
        FileHandle.standardError.write(Data("""
            Space Time Continuum can't read /dev/input. Add yourself to the input group and log in again:
                sudo usermod -aG input \(user)

            """.utf8))
    }

    func start() throws {
        rescan()
        // There's no udev binding here, so poll for hot-plugged devices.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.rescan() }
        timer.resume()
        rescanTimer = timer
    }

    func stop() {
        rescanTimer?.cancel()
        rescanTimer = nil
        grabRetry?.cancel()
        grabRetry = nil
        lock.lock()
        let devices = open.values
        open.removeAll()
        lock.unlock()
        for d in devices { close(d.fd) }
    }

    // MARK: Devices

    private static func eventNodes() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/input")) ?? []
        return names.filter { $0.hasPrefix("event") }.sorted().map { "/dev/input/\($0)" }
    }

    private func rescan() {
        var changed = false
        for path in Self.eventNodes() {
            lock.lock()
            let known = open[path] != nil
            lock.unlock()
            if known { continue }
            guard let device = probe(path) else { continue }
            lock.lock()
            open[path] = device
            lock.unlock()
            if device.keyboard != nil { changed = true }
            let thread = Thread { [weak self] in self?.readLoop(device) }
            thread.name = "evdev \(path)"
            thread.start()
        }
        if changed { onKeyboardsChanged?() }
        if !blockedDevices.isEmpty { applyGrabs() }
    }

    // MARK: Blocking

    private func applyGrabs() {
        lock.lock()
        let devices = Array(open.values)
        lock.unlock()
        var waiting = false
        for d in devices {
            let want = (d.keyboard != nil && blockedDevices.contains(.keyboard))
                || (d.isPointer && blockedDevices.contains(.pointer))
            guard want != d.grabbed else { continue }
            // Grabbing while a key is held would leave the desktop seeing it held forever
            // (auto-repeat runaway), so wait until every key on that device is up.
            if want, d.keyboard != nil, anyKeyDown(d.fd) {
                waiting = true
                continue
            }
            if ioctl(d.fd, ioc(write: 0x90, size: 4), want ? 1 : 0) == 0 || !want {
                d.grabbed = want
            }
        }
        if waiting, grabRetry == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.applyGrabs() }
            timer.resume()
            grabRetry = timer
        } else if !waiting {
            grabRetry?.cancel()
            grabRetry = nil
        }
    }

    private func anyKeyDown(_ fd: Int32) -> Bool {
        var state = [UInt8](repeating: 0, count: KEY_MAX / 8 + 1)
        guard ioctl(fd, ioc(read: 0x18, size: state.count), &state) >= 0 else { return false }
        return state.contains { $0 != 0 }
    }

    /// Opens a device if it's a keyboard or pointer we care about.
    private func probe(_ path: String) -> OpenDevice? {
        let fd = Glibc.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }

        let evBits = bits(fd, type: 0, count: EV_MAX)
        let keyBits = evBits.contains(EV_KEY) ? bits(fd, type: EV_KEY, count: KEY_MAX) : []
        let relBits = evBits.contains(EV_REL) ? bits(fd, type: EV_REL, count: REL_MAX) : []
        let absBits = evBits.contains(EV_ABS) ? bits(fd, type: EV_ABS, count: ABS_MAX) : []

        let name = deviceName(fd)
        let id = deviceID(fd)
        // Something you type on has letters and a space bar, which rules out power buttons and the like.
        let isKeyboard = [KEY_A, KEY_Z, KEY_SPACE].allSatisfy(keyBits.contains)
            && !KeyboardDevice.isIgnored(productName: name)
        let isMouse = relBits.contains(REL_X) && relBits.contains(REL_Y)
        // Touchpads and the "USB tablet" pointer most VMs provide report absolute positions.
        let isAbsolute = !isMouse && absBits.contains(ABS_X) && absBits.contains(ABS_Y) && keyBits.contains(BTN_LEFT)

        guard isKeyboard || isMouse || isAbsolute else {
            close(fd)
            return nil
        }
        let keyboard = isKeyboard ? KeyboardDevice(
            vendorID: Int(id.vendor), productID: Int(id.product), productName: name,
            isBuiltIn: id.bustype == BUS_I8042 || name.localizedCaseInsensitiveContains("internal")
        ) : nil
        return OpenDevice(path: path, fd: fd, keyboard: keyboard, isPointer: isMouse || isAbsolute,
                          absScale: isAbsolute ? absScale(fd) : nil)
    }

    /// Meters per absolute unit on each axis.
    private func absScale(_ fd: Int32) -> (x: Double, y: Double) {
        func axis(_ code: Int) -> Double {
            var info = [Int32](repeating: 0, count: 6) // value, min, max, fuzz, flat, resolution
            guard ioctl(fd, ioc(read: 0x40 + UInt(code), size: 24), &info) >= 0 else { return 0 }
            let range = Double(info[2] - info[1])
            let resolution = Double(info[5]) // units per mm
            if resolution > 0 { return 0.001 / resolution }
            // No physical size (VM tablets): assume the range spans a 1920-point-wide screen.
            return range > 0 ? 1920 / range * DisplayGeometry.fallbackMetersPerPoint : 0
        }
        return (axis(ABS_X), axis(ABS_Y))
    }

    private func readLoop(_ device: OpenDevice) {
        let eventSize = 24 // struct input_event on 64-bit: timeval(16) + type(2) + code(2) + value(4)
        var buffer = [UInt8](repeating: 0, count: eventSize * 64)
        var dx = 0.0, dy = 0.0
        var lastAbs: (x: Int32?, y: Int32?) = (nil, nil)
        var touching = true

        while true {
            let n = buffer.withUnsafeMutableBytes { read(device.fd, $0.baseAddress, $0.count) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                break
            }
            for offset in stride(from: 0, to: n - eventSize + 1, by: eventSize) {
                let (type, code, value) = buffer.withUnsafeBytes { raw in
                    (raw.loadUnaligned(fromByteOffset: offset + 16, as: UInt16.self),
                     raw.loadUnaligned(fromByteOffset: offset + 18, as: UInt16.self),
                     raw.loadUnaligned(fromByteOffset: offset + 20, as: Int32.self))
                }
                switch (Int(type), Int(code)) {
                case (EV_KEY, let key):
                    if let keyboard = device.keyboard, value == 1, key > 0, key < BTN_MISC {
                        DispatchQueue.main.async { [weak self] in self?.onKeyPress?(keyboard, key) }
                    }
                    if key == BTN_TOUCH {
                        touching = value != 0
                        lastAbs = (nil, nil)
                    }
                case (EV_REL, REL_X): dx += Double(value) / mouseDPI * 0.0254
                case (EV_REL, REL_Y): dy += Double(value) / mouseDPI * 0.0254
                case (EV_ABS, ABS_X):
                    if let scale = device.absScale, touching, let last = lastAbs.x { dx += Double(value - last) * scale.x }
                    lastAbs.x = value
                case (EV_ABS, ABS_Y):
                    if let scale = device.absScale, touching, let last = lastAbs.y { dy += Double(value - last) * scale.y }
                    lastAbs.y = value
                case (EV_SYN, _):
                    let meters = hypot(dx, dy)
                    dx = 0; dy = 0
                    if meters > 0 {
                        DispatchQueue.main.async { [weak self] in self?.onPointerMove?(meters) }
                    }
                default: break
                }
            }
        }

        // Unplugged (ENODEV) or closed by stop().
        lock.lock()
        let wasOpen = open[device.path] === device
        if wasOpen { open[device.path] = nil }
        lock.unlock()
        if wasOpen {
            close(device.fd)
            if device.keyboard != nil {
                DispatchQueue.main.async { [weak self] in self?.onKeyboardsChanged?() }
            }
        }
    }

    // MARK: ioctl helpers

    private func ioc(read nr: UInt, size: Int) -> UInt {
        (2 << 30) | (UInt(size) << 16) | (UInt(UInt8(ascii: "E")) << 8) | nr
    }

    private func ioc(write nr: UInt, size: Int) -> UInt {
        (1 << 30) | (UInt(size) << 16) | (UInt(UInt8(ascii: "E")) << 8) | nr
    }

    private func bits(_ fd: Int32, type: Int, count: Int) -> Set<Int> {
        var bytes = [UInt8](repeating: 0, count: count / 8 + 1)
        guard ioctl(fd, ioc(read: 0x20 + UInt(type), size: bytes.count), &bytes) >= 0 else { return [] }
        var result = Set<Int>()
        for (i, byte) in bytes.enumerated() where byte != 0 {
            for bit in 0..<8 where byte & (1 << bit) != 0 { result.insert(i * 8 + bit) }
        }
        return result
    }

    private func deviceName(_ fd: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard ioctl(fd, ioc(read: 0x06, size: buf.count), &buf) >= 0 else { return "Unknown keyboard" }
        return String(cString: buf)
    }

    private func deviceID(_ fd: Int32) -> (bustype: UInt16, vendor: UInt16, product: UInt16) {
        var id = [UInt16](repeating: 0, count: 4) // bustype, vendor, product, version
        guard ioctl(fd, ioc(read: 0x02, size: 8), &id) >= 0 else { return (0, 0, 0) }
        return (id[0], id[1], id[2])
    }
}

// From <linux/input-event-codes.h>.
private let EV_SYN = 0x00, EV_KEY = 0x01, EV_REL = 0x02, EV_ABS = 0x03, EV_MAX = 0x1f
private let KEY_A = 30, KEY_Z = 44, KEY_SPACE = 57, KEY_MAX = 0x2ff
private let BTN_MISC = 0x100, BTN_TOUCH = 0x14a, BTN_LEFT = 0x110
private let REL_X = 0x00, REL_Y = 0x01, REL_MAX = 0x0f
private let ABS_X = 0x00, ABS_Y = 0x01, ABS_MAX = 0x3f
private let BUS_I8042: UInt16 = 0x11
