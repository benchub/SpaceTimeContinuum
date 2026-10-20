import Foundation
import STCCore

/// Headless recorder: input → Recorder → SQLite, plus Nanny notifications. Main-queue only.
final class Daemon {
    let store: ActivityStore
    let keyboardCatalog: KeyboardCatalog
    let formatter: SillyFormatter
    private(set) var settings: AppSettings
    private let session = LinuxSessionState()
    let input = LinuxInputMonitor()
    let loginItem = LinuxLoginItem()
    private let notifier = LinuxNotifier()
    private let recorder: Recorder
    private var stretch = StretchTracker()
    private var quipRotation = QuipRotation()
    private var travelMetersByKeyboard: [String: Double] = [:]
    private var tickTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []

    static let mouseDPIKey = "linux_mouse_dpi"

    init() throws {
        let dir = Self.dataDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try ActivityStore(path: dir.appendingPathComponent("spacetime.sqlite").path)
        settings = try store.loadSettings()
        keyboardCatalog = (try? KeyboardCatalog(data: Resources.data("keyboards"))) ?? KeyboardCatalog()
        formatter = SillyFormatter(catalog: try UnitCatalog(data: Resources.data("units")))
        recorder = Recorder(session: session)
        if let dpi = (try? store.setting(Self.mouseDPIKey)).flatMap({ $0.flatMap(Double.init) }), dpi > 0 {
            input.mouseDPI = dpi
        }
    }

    /// `$STC_DATA_DIR`, else `$XDG_DATA_HOME/SpaceTimeContinuum` (~/.local/share by default).
    static func dataDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["STC_DATA_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        let base = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("SpaceTimeContinuum", isDirectory: true)
    }

    func run() -> Never {
        recorder.onMinute = { [weak self] rollup in self?.persist(rollup) }
        input.onKeyPress = { [weak self] keyboard in
            guard let self else { return }
            let meters = self.travelMetersByKeyboard[keyboard.id] ?? self.travelMeters(for: keyboard)
            self.recorder.recordKeyPress(travelMeters: meters)
        }
        input.onPointerMove = { [weak self] meters in self?.recorder.recordPointerMovement(meters: meters) }
        input.onKeyboardsChanged = { [weak self] in self?.keyboardsChanged() }

        if !input.hasPermission { input.requestPermission() }
        try? input.start()
        keyboardsChanged()

        if !settings.configured {
            // No first-run window on Linux yet; accept the defaults.
            updateSettings { $0.configured = true }
            if settings.launchAtLogin { try? loginItem.setEnabled(true) }
        }

        // Tick just after each second boundary.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = 1.05 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        timer.schedule(deadline: .now() + delay, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.recorder.tick() }
        timer.resume()
        tickTimer = timer

        // Write the partial minute on the way out.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.recorder.flush()
                self?.input.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        print("Space Time Continuum is recording to \(Self.dataDirectory().path)")
        dispatchMain()
    }

    private func persist(_ rollup: MinuteRollup) {
        do {
            try store.record(rollup)
        } catch {
            FileHandle.standardError.write(Data("Failed to record minute: \(error)\n".utf8))
        }
        // Settings may have been changed by another `stcd` command.
        if let fresh = try? store.loadSettings() { settings = fresh }
        checkNanny()
        checkStretch(rollup)
    }

    private func checkNanny() {
        guard settings.nannyEnabled else { return }
        let now = Date()
        let nanny = Nanny(rules: settings.nannyRules)
        let since = Int64(now.timeIntervalSince1970) - Int64(nanny.historyMinutes * 60) - 60
        guard let recent = try? store.minutes(from: since, to: Int64(now.timeIntervalSince1970) + 60),
              let reason = nanny.evaluate(recent: recent, now: now, lastNagAt: settings.lastNagAt)
        else { return }
        let message = Nanny.message(for: reason)
        notifier.notify(title: message.title, body: message.body)
        updateSettings { $0.lastNagAt = now }
    }

    private func checkStretch(_ rollup: MinuteRollup) {
        guard settings.nannyEnabled, settings.nannyRules.stretchEnabled else { stretch.reset(); return }
        if stretch.add(minuteStart: rollup.minuteStart, attentiveSeconds: rollup.activity.attentiveSeconds, everyMinutes: settings.nannyRules.stretchEveryMinutes) {
            let message = Nanny.stretchMessage(body: quipRotation.next(from: Nanny.stretchSuggestions))
            notifier.notify(title: message.title, body: message.body)
        }
    }

    private func keyboardsChanged() {
        travelMetersByKeyboard = Dictionary(input.keyboards.map { ($0.id, travelMeters(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    func travelMeters(for keyboard: KeyboardDevice) -> Double {
        settings.travelMM(for: keyboard, catalog: keyboardCatalog) / 1000
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = settings
        change(&s)
        settings = s
        try? store.saveSettings(s)
    }

    /// Today's and lifetime totals as printable lines.
    func summary() -> String {
        let today = (try? store.dayActivity(containing: Date())) ?? .zero
        let lifetime = (try? store.totals()) ?? LifetimeTotals()
        func block(_ title: String, _ a: Activity) -> String {
            """
            \(title)
              Keyboard: \(Self.duration(a.keyActiveSeconds)), \(a.keyPresses) presses, \(formatter.format(a.keyDistanceMeters, .space))
              Pointer:  \(Self.duration(a.pointerActiveSeconds)), \(formatter.format(a.pointerDistanceMeters, .space))
              Screen on and unlocked: \(Self.duration(a.attentiveSeconds))
            """
        }
        return block("Today", today) + "\n" + block("Lifetime", lifetime.activity)
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m \(seconds % 60)s"
    }
}

/// Locates the shared JSON data files: `$STC_SHARED_DIR`, an installed copy, or the source tree.
enum Resources {
    static func data(_ name: String) throws -> Data {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        var candidates: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["STC_SHARED_DIR"], !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: dir))
        }
        candidates += [
            exeDir.appendingPathComponent("../share/spacetimecontinuum"),
            URL(fileURLWithPath: "/usr/share/spacetimecontinuum"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared"),
        ]
        for dir in candidates {
            let url = dir.appendingPathComponent("\(name).json")
            if FileManager.default.fileExists(atPath: url.path) { return try Data(contentsOf: url) }
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).json"])
    }
}
