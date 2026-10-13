import AppKit
import Combine
import STCCore

/// Owns recording, storage, settings and background services. Main-thread only.
@MainActor
final class AppModel: ObservableObject {
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    @Published private(set) var settings: AppSettings
    @Published private(set) var keyboards: [KeyboardDevice] = []
    @Published private(set) var hasInputPermission = false
    @Published private(set) var loginItemError: String?
    @Published private(set) var nameState: NameAvailabilityChecker.State = .idle
    @Published private(set) var nameClaimMessage: (text: String, success: Bool)?
    /// Bumped after every minute write so graphs can refresh.
    @Published private(set) var dataVersion = 0

    let store: ActivityStore
    let keyboardCatalog: KeyboardCatalog
    private(set) var formatter: SillyFormatter
    private let bundledUnits: UnitCatalog
    private let recorder: Recorder
    private let session = MacSessionState()
    private let input = MacInputMonitor()
    private let loginItem = MacLoginItem()
    private let notifier = MacNotifier()
    private let nanny = Nanny()
    private let client: LeaderboardClient
    private let unitsUpdater: UnitsUpdater
    private let sync: SyncService
    private let nameChecker: NameAvailabilityChecker
    private var travelMetersByKeyboard: [String: Double] = [:]
    private var tickTimer: Timer?
    private var hourlyTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() throws {
        let support: URL
        if let override = ProcessInfo.processInfo.environment["STC_DATA_DIR"], !override.isEmpty {
            support = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SpaceTimeContinuum", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        store = try ActivityStore(path: support.appendingPathComponent("spacetime.sqlite").path)
        settings = try store.loadSettings()
        keyboardCatalog = (try? KeyboardCatalog(data: Resources.data("keyboards"))) ?? KeyboardCatalog()
        bundledUnits = try UnitCatalog(data: Resources.data("units"))

        let os = ProcessInfo.processInfo.operatingSystemVersion
        client = LeaderboardClient(userAgent: "SpaceTimeContinuum/\(Self.appVersion) (macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))")
        unitsUpdater = UnitsUpdater(client: client, cacheURL: support.appendingPathComponent("units-cache.json"))
        formatter = SillyFormatter(catalog: bundledUnits)
        recorder = Recorder(session: session)

        var settingsRef: () -> AppSettings = { AppSettings() }
        sync = SyncService(store: store, client: client, session: session, settings: { settingsRef() })
        var guidRef: () -> String = { "" }
        nameChecker = NameAvailabilityChecker(client: client, guid: { guidRef() })
        settingsRef = { [unowned self] in self.settings }
        guidRef = { [unowned self] in self.settings.deviceGUID }
        nameChecker.onChange = { [weak self] in self?.nameState = $0 }

        applyUnitsCatalog()
    }

    var isFirstRun: Bool { !settings.configured }

    // MARK: Lifecycle

    func start() {
        recorder.onMinute = { [weak self] rollup in
            MainActor.assumeIsolated { self?.persist(rollup) }
        }
        input.onKeyPress = { [weak self] keyboard in
            guard let self else { return }
            let meters = self.travelMetersByKeyboard[keyboard.id] ?? self.travelMeters(for: keyboard)
            self.recorder.recordKeyPress(travelMeters: meters)
        }
        input.onPointerMove = { [weak self] meters in self?.recorder.recordPointerMovement(meters: meters) }
        input.onKeyboardsChanged = { [weak self] in self?.keyboardsChanged() }

        hasInputPermission = input.hasPermission
        if !hasInputPermission { input.requestPermission() }
        try? input.start()
        keyboardsChanged()

        // Align ticks just after each second boundary; .common so they keep firing while menus are open.
        let delay = 1.05 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            self.tickTimer = timer
        }

        let hourly = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundChores() }
        }
        RunLoop.main.add(hourly, forMode: .common)
        hourlyTimer = hourly

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recorder.flush() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.input.resetPointer()
                self?.backgroundChores()
            }
        })

        if settings.launchAtLogin && settings.configured { setLaunchAtLogin(true) }
        if settings.nannyEnabled { notifier.requestAuthorization() }
        sync.start()
        backgroundChores()
    }

    /// Writes the partial minute; called before quitting.
    func shutdown() {
        tickTimer?.invalidate()
        recorder.flush()
        input.stop()
        sync.stop()
    }

    private func tick() {
        recorder.tick()
        let granted = input.hasPermission
        if granted != hasInputPermission {
            hasInputPermission = granted
            if granted { input.restart() }
        }
    }

    private func persist(_ rollup: MinuteRollup) {
        do {
            try store.record(rollup)
        } catch {
            NSLog("Failed to record minute: \(error)")
        }
        dataVersion += 1
        checkNanny()
    }

    private func backgroundChores() {
        guard settings.newEntropyEnabled, unitsUpdater.isDue(lastChecked: settings.unitsLastChecked) else { return }
        Task {
            let outcome = await unitsUpdater.fetch(etag: settings.unitsETag)
            switch outcome {
            case .updated(_, let etag):
                updateSettings { $0.unitsETag = etag; $0.unitsLastChecked = Date() }
                applyUnitsCatalog()
            case .notModified, .invalid:
                updateSettings { $0.unitsLastChecked = Date() }
            case .failed(let message):
                NSLog("New Entropy fetch failed: \(message)")
            }
        }
    }

    private func applyUnitsCatalog() {
        let catalog = settings.newEntropyEnabled ? (unitsUpdater.loadCached() ?? bundledUnits) : bundledUnits
        formatter = SillyFormatter(catalog: catalog)
    }

    private func checkNanny() {
        guard settings.nannyEnabled else { return }
        let now = Date()
        let since = Int64(now.timeIntervalSince1970) - Int64(nanny.sessionWindowMinutes * 60) - 60
        guard let recent = try? store.minutes(from: since, to: Int64(now.timeIntervalSince1970) + 60),
              let reason = nanny.evaluate(recent: recent, now: now, lastNagAt: settings.lastNagAt)
        else { return }
        let message = Nanny.message(for: reason)
        notifier.notify(title: message.title, body: message.body)
        updateSettings { $0.lastNagAt = now }
    }

    // MARK: Reading for the menu

    struct Snapshot {
        var today: Activity
        var lifetime: LifetimeTotals
    }

    func snapshot() -> Snapshot {
        let live = recorder.currentMinuteActivity
        let today = ((try? store.dayActivity(containing: Date())) ?? .zero) + live
        var lifetime = (try? store.totals()) ?? LifetimeTotals()
        lifetime.activity += live
        return Snapshot(today: today, lifetime: lifetime)
    }

    func silly(_ value: Double, _ kind: MeasureKind) -> String { formatter.format(value, kind) }

    func stableSilly(_ value: Double, _ kind: MeasureKind, salt: Int = 0) -> String {
        var rng = SeededRandom(value, salt: salt)
        return formatter.format(value, kind, using: &rng)
    }

    // MARK: Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        try? store.saveSettings(s)
        recomputeTravel()
    }

    func travelMeters(for keyboard: KeyboardDevice) -> Double {
        settings.travelMM(for: keyboard, catalog: keyboardCatalog) / 1000
    }

    func travelMM(for keyboard: KeyboardDevice) -> Double {
        settings.travelMM(for: keyboard, catalog: keyboardCatalog)
    }

    func setTravelMM(_ mm: Double, for keyboard: KeyboardDevice) {
        let clamped = min(max(mm, 0.1), 10)
        updateSettings { $0.keyboardTravelMM[keyboard.id] = clamped }
    }

    private func keyboardsChanged() {
        keyboards = input.keyboards
        recomputeTravel()
    }

    private func recomputeTravel() {
        travelMetersByKeyboard = Dictionary(keyboards.map { ($0.id, travelMeters(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't update login item: \(error.localizedDescription)"
        }
        updateSettings { $0.launchAtLogin = enabled }
    }

    func setNanny(_ enabled: Bool) {
        if enabled { notifier.requestAuthorization() }
        updateSettings { $0.nannyEnabled = enabled }
    }

    func setNewEntropy(_ enabled: Bool) {
        updateSettings {
            $0.newEntropyEnabled = enabled
            if enabled { $0.unitsLastChecked = nil }
        }
        applyUnitsCatalog()
        if enabled { backgroundChores() }
    }

    func setLeaderboardEnabled(_ enabled: Bool) {
        guard Features.leaderboardAvailable else { return }
        updateSettings { $0.leaderboardEnabled = enabled }
    }

    func leaderboardNameEdited(_ name: String) {
        nameClaimMessage = nil
        guard Features.leaderboardAvailable else { return }
        nameChecker.update(name)
    }

    func claimLeaderboardName(_ raw: String) {
        let name = LeaderboardName.normalize(raw)
        Task {
            switch await client.claimName(guid: settings.deviceGUID, token: settings.deviceToken, name: name) {
            case .success(let claimed):
                updateSettings { $0.leaderboardName = claimed }
                nameClaimMessage = ("Your leaderboard name is now \(claimed).", true)
            case .unavailable(let n):
                nameState = .unavailable(reason: "taken")
                nameClaimMessage = ("Someone just claimed \(n). Try another name.", false)
            case .error(let message):
                nameClaimMessage = ("Couldn't set the name: \(message)", false)
            }
        }
    }

    func finishConfiguration() {
        let first = !settings.configured
        updateSettings { $0.configured = true }
        if first && settings.launchAtLogin { setLaunchAtLogin(true) }
    }

    /// Erases all time and distance data and starts over with a new leaderboard identity.
    func resetHistory() {
        recorder.discard()
        do {
            try store.resetActivity()
        } catch {
            NSLog("Reset failed: \(error)")
        }
        updateSettings { $0.regenerateIdentity() }
        dataVersion += 1
    }

    func requestInputPermission() {
        input.requestPermission()
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Locates the bundled JSON data files: inside the .app, or in the source tree when run via `swift run`.
enum Resources {
    static func data(_ name: String) throws -> Data {
        if let url = Bundle.main.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/\(name).json")
        return try Data(contentsOf: shared)
    }
}
