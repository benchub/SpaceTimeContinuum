import Foundation
import STCCore

/// Recorder, storage, reminders, Mistress Mode and background services. Main thread only.
///
/// `run()` shows the tray icon when there's a display and runs headless otherwise.
@MainActor
final class Daemon {
    static let appVersion = "0.1"
    static let mouseDPIKey = "linux_mouse_dpi"

    let store: ActivityStore
    let keyboardCatalog: KeyboardCatalog
    private(set) var formatter: SillyFormatter
    private(set) var settings: AppSettings
    let input = LinuxInputMonitor()
    let loginItem = LinuxLoginItem()
    let client: LeaderboardClient
    private let session = LinuxSessionState()
    private let notifier = LinuxNotifier()
    private let recorder: Recorder
    private let bundledUnits: UnitCatalog
    private let unitsUpdater: UnitsUpdater
    private let quipsUpdater: QuipsUpdater
    private let sync: SyncService
    private var stretch = StretchTracker()
    private var quipRotation = QuipRotation()
    private var downloadedStretchQuips: [String] = []
    private var engine = EnforcementEngine()
    private var lockouts = LockoutScheduler()
    private let overlay = EnforcementOverlay()
    private var tray: TrayIcon?
    private var recentKeys: [Int] = []
    private var travelMetersByKeyboard: [String: Double] = [:]
    private var timers: [DispatchSourceTimer] = []
    private var signalSources: [DispatchSourceSignal] = []

    init() throws {
        let dir = Self.dataDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try ActivityStore(path: dir.appendingPathComponent("spacetime.sqlite").path)
        settings = try store.loadSettings()
        keyboardCatalog = (try? KeyboardCatalog(data: Resources.data("keyboards"))) ?? KeyboardCatalog()
        bundledUnits = try UnitCatalog(data: Resources.data("units"))
        formatter = SillyFormatter(catalog: bundledUnits)
        recorder = Recorder(session: session)

        client = LeaderboardClient(userAgent: "SpaceTimeContinuum/\(Self.appVersion) (\(Self.osName()))")
        unitsUpdater = UnitsUpdater(client: client, cacheURL: dir.appendingPathComponent("units-cache.json"))
        quipsUpdater = QuipsUpdater(client: client, cacheURL: dir.appendingPathComponent("quips-cache.json"))
        var settingsRef: () -> AppSettings = { AppSettings() }
        sync = SyncService(store: store, client: client, session: session, settings: { settingsRef() })
        settingsRef = { [unowned self] in self.settings }

        if let dpi = (try? store.setting(Self.mouseDPIKey)).flatMap({ $0.flatMap(Double.init) }), dpi > 0 {
            input.mouseDPI = dpi
        }
        applyUnitsCatalog()
    }

    /// `$STC_DATA_DIR`, else `$XDG_DATA_HOME/SpaceTimeContinuum` (~/.local/share by default).
    nonisolated static func dataDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["STC_DATA_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        let base = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("SpaceTimeContinuum", isDirectory: true)
    }

    private static func osName() -> String {
        let release = (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? ""
        let pretty = release.split(separator: "\n").first { $0.hasPrefix("PRETTY_NAME=") }
        return pretty.map { $0.dropFirst("PRETTY_NAME=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } ?? "Linux"
    }

    // MARK: Lifecycle

    func run() -> Never {
        recorder.onMinute = { [weak self] rollup in
            MainActor.assumeIsolated { self?.persist(rollup) }
        }
        input.onKeyPress = { [weak self] keyboard, code in
            MainActor.assumeIsolated { self?.keyPressed(keyboard, code: code) }
        }
        input.onPointerMove = { [weak self] meters in
            MainActor.assumeIsolated {
                guard let self, !self.engine.lockedDevices.contains(.pointer) else { return }
                self.recorder.recordPointerMovement(meters: meters)
            }
        }
        input.onKeyboardsChanged = { [weak self] in
            MainActor.assumeIsolated { self?.keyboardsChanged() }
        }

        if !input.hasPermission { input.requestPermission() }
        try? input.start()
        keyboardsChanged()

        if !settings.configured {
            // No first-run window on Linux yet; accept the defaults.
            updateSettings { $0.configured = true }
        }
        if settings.launchAtLogin { try? loginItem.setEnabled(true) }

        // Tick just after each second boundary.
        let delay = 1.05 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        repeating(every: 1, after: delay) { $0.tick() }
        repeating(every: 3600, after: 5) { $0.backgroundChores() }
        sync.start()

        // Write the partial minute and release any grabs on the way out.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { if let self { self.quit() } }
            }
            source.resume()
            signalSources.append(source)
        }

        print("Space Time Continuum is recording to \(Self.dataDirectory().path)")
        if Gtk.initialize() {
            tray = TrayIcon(daemon: self)
            overlay.onExtend = { [weak self] (id: Int) in self?.extendWarning(id) }
            Gtk.main()
        }
        dispatchMain()
    }

    func quit() -> Never {
        recorder.flush()
        input.blockedDevices = []
        input.stop()
        exit(0)
    }

    private func repeating(every seconds: Double, after delay: Double, _ action: @escaping (Daemon) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay, repeating: seconds, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        timer.resume()
        timers.append(timer)
    }

    private var tickCount = 0

    private func tick() {
        recorder.tick()
        if engine.tick(now: Date()) { syncEnforcement() }
        if !engine.active.isEmpty { overlay.show(engine.active, safeWordEnabled: settings.mistressRules.safeWordEnabled) }
        tickCount += 1
        if tickCount % 5 == 0 { tray?.refresh() }
    }

    private func keyPressed(_ keyboard: KeyboardDevice, code: Int) {
        if engine.lockedDevices.isEmpty {
            recentKeys.removeAll()
        } else {
            checkSafeWord(code)
        }
        guard !engine.lockedDevices.contains(.keyboard) else { return }
        let meters = travelMetersByKeyboard[keyboard.id] ?? travelMeters(for: keyboard)
        recorder.recordKeyPress(travelMeters: meters)
    }

    private func persist(_ rollup: MinuteRollup) {
        do {
            try store.record(rollup)
        } catch {
            FileHandle.standardError.write(Data("Failed to record minute: \(error)\n".utf8))
        }
        // Pick up changes made by other `stcd` commands.
        if let fresh = try? store.loadSettings(), fresh != settings {
            let entropyChanged = fresh.newEntropyEnabled != settings.newEntropyEnabled
            settings = fresh
            if entropyChanged { applyUnitsCatalog() }
            if !settings.mistressEnabled { cancelMistress() }
            tray?.refresh()
        }
        checkNanny()
        checkStretch(rollup)
        checkLockouts(rollup)
    }

    // MARK: Nanny

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
        if settings.mistressEnabled {
            startEnforcement(devices: [.keyboard, .pointer], reason: message.title, lockMinutes: Nanny.breakMinutes)
        }
    }

    private func checkStretch(_ rollup: MinuteRollup) {
        guard settings.nannyEnabled, settings.nannyRules.stretchEnabled else { stretch.reset(); return }
        if stretch.add(minuteStart: rollup.minuteStart, attentiveSeconds: rollup.activity.attentiveSeconds, everyMinutes: settings.nannyRules.stretchEveryMinutes) {
            let message = Nanny.stretchMessage(body: quipRotation.next(from: Nanny.stretchSuggestions + downloadedStretchQuips))
            notifier.notify(title: message.title, body: message.body)
        }
    }

    // MARK: Mistress Mode

    private static let safeWord = [22, 49, 46, 38, 18] // U N C L E

    private func checkLockouts(_ rollup: MinuteRollup) {
        guard settings.mistressEnabled else { lockouts.reset(); return }
        guard let trip = lockouts.ingest(minuteStart: rollup.minuteStart, activity: rollup.activity, rules: settings.mistressRules) else { return }
        let what = trip.devices.count == 2 ? "keyboard and mouse" : (trip.devices.contains(.keyboard) ? "keyboard" : "mouse")
        startEnforcement(devices: trip.devices, reason: "Time for a \(what) break", lockMinutes: trip.lockMinutes)
    }

    private func startEnforcement(devices: Set<InputDevice>, reason: String, lockMinutes: Int) {
        let warning = settings.mistressRules.warningMinutes
        engine.request(
            devices: devices, reason: reason,
            lockSeconds: TimeInterval(max(1, lockMinutes) * 60),
            warningSeconds: TimeInterval(warning * 60),
            now: Date()
        )
        if warning > 0 {
            notifier.notify(title: reason, body: "Input will be blocked in \(warning) minute\(warning == 1 ? "" : "s").")
        }
        syncEnforcement()
    }

    /// Brings the grabs and the countdown window in line with the engine.
    private func syncEnforcement() {
        let locked = engine.lockedDevices
        if locked != input.blockedDevices { input.blockedDevices = locked }
        overlay.show(engine.active, safeWordEnabled: settings.mistressRules.safeWordEnabled)
    }

    private func checkSafeWord(_ code: Int) {
        guard settings.mistressRules.safeWordEnabled else { return }
        recentKeys.append(code)
        if recentKeys.count > Self.safeWord.count { recentKeys.removeFirst() }
        guard recentKeys == Self.safeWord else { return }
        recentKeys.removeAll()
        for e in engine.active where e.phase == .locked { engine.endLock(id: e.id) }
        syncEnforcement()
    }

    func extendWarning(_ id: Int) {
        if engine.extendWarning(id: id, by: 5 * 60) { syncEnforcement() }
    }

    private func cancelMistress() {
        engine.cancelAll()
        lockouts.reset()
        syncEnforcement()
    }

    // MARK: New Entropy

    private func backgroundChores() {
        guard settings.newEntropyEnabled else { return }
        if quipsUpdater.isDue(lastChecked: settings.quipsLastChecked) {
            Task {
                switch await quipsUpdater.fetch(etag: settings.quipsETag) {
                case .updated(let etag):
                    updateSettings { $0.quipsETag = etag; $0.quipsLastChecked = Date() }
                    applyUnitsCatalog()
                case .notModified, .invalid:
                    updateSettings { $0.quipsLastChecked = Date() }
                case .failed(let message):
                    FileHandle.standardError.write(Data("New Entropy quips fetch failed: \(message)\n".utf8))
                }
            }
        }
        guard unitsUpdater.isDue(lastChecked: settings.unitsLastChecked) else { return }
        Task {
            switch await unitsUpdater.fetch(etag: settings.unitsETag) {
            case .updated(_, let etag):
                updateSettings { $0.unitsETag = etag; $0.unitsLastChecked = Date() }
                applyUnitsCatalog()
            case .notModified, .invalid:
                updateSettings { $0.unitsLastChecked = Date() }
            case .failed(let message):
                FileHandle.standardError.write(Data("New Entropy fetch failed: \(message)\n".utf8))
            }
        }
    }

    private func applyUnitsCatalog() {
        let catalog = settings.newEntropyEnabled ? (unitsUpdater.loadCached() ?? bundledUnits) : bundledUnits
        formatter = SillyFormatter(catalog: catalog)
        downloadedStretchQuips = settings.newEntropyEnabled ? (quipsUpdater.loadCached()?.stretch ?? []) : []
    }

    // MARK: Settings

    func setNanny(_ enabled: Bool) { updateSettings { $0.nannyEnabled = enabled } }

    func setMistress(_ enabled: Bool) {
        updateSettings { $0.mistressEnabled = enabled }
        if !enabled { cancelMistress() }
    }

    func setNewEntropy(_ enabled: Bool) {
        updateSettings {
            $0.newEntropyEnabled = enabled
            if enabled { $0.unitsLastChecked = nil; $0.quipsLastChecked = nil }
        }
        applyUnitsCatalog()
        if enabled { backgroundChores() }
    }

    func setLeaderboardEnabled(_ enabled: Bool) {
        guard Features.leaderboardAvailable else { return }
        updateSettings { $0.leaderboardEnabled = enabled }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            updateSettings { $0.launchAtLogin = enabled }
        } catch {
            notifier.notify(title: "Couldn't change Start at login", body: "\(error)")
        }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = settings
        change(&s)
        settings = s
        try? store.saveSettings(s)
    }

    private func keyboardsChanged() {
        travelMetersByKeyboard = Dictionary(input.keyboards.map { ($0.id, travelMeters(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    func travelMeters(for keyboard: KeyboardDevice) -> Double {
        settings.travelMM(for: keyboard, catalog: keyboardCatalog) / 1000
    }

    // MARK: Reading

    /// Today's numbers for the tray menu, including the minute in progress.
    func menuLines() -> [String] {
        let today = ((try? store.dayActivity(containing: Date())) ?? .zero) + recorder.currentMinuteActivity
        let lifetime = (try? store.totals())?.activity ?? .zero
        var lines = [
            "Keyboard today: \(Self.duration(today.keyActiveSeconds))",
            "Mouse today: \(Self.duration(today.pointerActiveSeconds))",
            "Keys traveled: \(formatter.format(lifetime.keyDistanceMeters, .space))",
            "Pointer traveled: \(formatter.format(lifetime.pointerDistanceMeters, .space))",
        ]
        if settings.leaderboardEnabled, !settings.leaderboardName.isEmpty, let last = sync.lastResult {
            lines[3] += " · \(last)"
        }
        return lines
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
        var text = block("Today", today) + "\n" + block("Lifetime", lifetime.activity)
        if settings.leaderboardEnabled {
            text += "\nLeaderboard: on as \(settings.leaderboardName.isEmpty ? "(no name yet)" : settings.leaderboardName)"
        }
        return text
    }

    nonisolated static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m \(seconds % 60)s"
    }
}

/// Locates the shared data files: `$STC_SHARED_DIR`, an installed copy, or the source tree.
enum Resources {
    static func url(_ name: String, _ ext: String) -> URL? {
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
        return candidates.map { $0.appendingPathComponent("\(name).\(ext)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func data(_ name: String) throws -> Data {
        guard let url = url(name, "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).json"])
        }
        return try Data(contentsOf: url)
    }
}
