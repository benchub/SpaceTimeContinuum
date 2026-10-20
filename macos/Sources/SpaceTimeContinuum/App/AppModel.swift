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
    /// The Mistress Mode warnings and lockouts in progress.
    @Published private(set) var enforcements: [Enforcement] = []
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var notificationsAllowed = true
    private var tickCount = 0

    let store: ActivityStore
    let keyboardCatalog: KeyboardCatalog
    private(set) var formatter: SillyFormatter
    private let bundledUnits: UnitCatalog
    private let recorder: Recorder
    private let session = MacSessionState()
    private let input = MacInputMonitor()
    private let loginItem = MacLoginItem()
    private let notifier = MacNotifier()
    private var nanny: Nanny { Nanny(rules: settings.nannyRules) }
    private var engine = EnforcementEngine()
    private var blockedDevices: Set<InputDevice> = []
    private var lockouts = LockoutScheduler()
    private var stretch = StretchTracker()
    private var quipRotation = QuipRotation()
    private var downloadedStretchQuips: [String] = []
    private let blocker = MacInputBlocker()
    private let overlay = EnforcementOverlay()
    private let client: LeaderboardClient
    private let unitsUpdater: UnitsUpdater
    private let quipsUpdater: QuipsUpdater
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
        quipsUpdater = QuipsUpdater(client: client, cacheURL: support.appendingPathComponent("quips-cache.json"))
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
            guard let self, !self.isBlocked(.keyboard) else { return }
            let meters = self.travelMetersByKeyboard[keyboard.id] ?? self.travelMeters(for: keyboard)
            self.recorder.recordKeyPress(travelMeters: meters)
        }
        input.onPointerMove = { [weak self] meters in
            guard let self, !self.isBlocked(.pointer) else { return }
            self.recorder.recordPointerMovement(meters: meters)
        }
        input.onKeyboardsChanged = { [weak self] in self?.keyboardsChanged() }
        blocker.passThroughRects = { [weak self] in self?.overlay.frames ?? [] }
        hasAccessibilityPermission = MacInputBlocker.isTrusted

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
        blocker.unblock()
        overlay.hide()
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
        let trusted = MacInputBlocker.isTrusted
        if trusted != hasAccessibilityPermission { hasAccessibilityPermission = trusted }
        tickCount += 1
        if tickCount % 3 == 0 { refreshNotificationStatus() }
        if engine.tick(now: Date()) { syncEnforcement() }
    }

    private func persist(_ rollup: MinuteRollup) {
        do {
            try store.record(rollup)
        } catch {
            NSLog("Failed to record minute: \(error)")
        }
        dataVersion += 1
        checkNanny()
        checkStretch(rollup)
        checkLockouts(rollup)
    }

    private func backgroundChores() {
        guard settings.newEntropyEnabled else { return }
        refreshQuips()
        guard unitsUpdater.isDue(lastChecked: settings.unitsLastChecked) else { return }
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

    private func refreshQuips() {
        guard quipsUpdater.isDue(lastChecked: settings.quipsLastChecked) else { return }
        Task {
            switch await quipsUpdater.fetch(etag: settings.quipsETag) {
            case .updated(let etag):
                updateSettings { $0.quipsETag = etag; $0.quipsLastChecked = Date() }
                applyUnitsCatalog()
            case .notModified, .invalid:
                updateSettings { $0.quipsLastChecked = Date() }
            case .failed(let message):
                NSLog("New Entropy quips fetch failed: \(message)")
            }
        }
    }

    private func applyUnitsCatalog() {
        let catalog = settings.newEntropyEnabled ? (unitsUpdater.loadCached() ?? bundledUnits) : bundledUnits
        formatter = SillyFormatter(catalog: catalog)
        downloadedStretchQuips = settings.newEntropyEnabled ? (quipsUpdater.loadCached()?.stretch ?? []) : []
    }

    private func checkNanny() {
        guard settings.nannyEnabled else { return }
        let now = Date()
        let nanny = nanny
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
            let pool = Nanny.stretchSuggestions + downloadedStretchQuips
            let message = Nanny.stretchMessage(body: quipRotation.next(from: pool))
            notifier.notify(title: message.title, body: message.body)
        }
    }

    // MARK: Mistress Mode

    private func isBlocked(_ device: InputDevice) -> Bool {
        enforcements.contains { $0.phase == .locked && $0.device == device }
    }

    private func checkLockouts(_ rollup: MinuteRollup) {
        guard settings.mistressEnabled else { lockouts.reset(); return }
        for trip in lockouts.ingest(minuteStart: rollup.minuteStart, activity: rollup.activity, rules: settings.mistressRules) {
            let what = trip.device == .keyboard ? "keyboard" : "mouse"
            startEnforcement(devices: [trip.device], reason: "Time for a \(what) break", lockMinutes: trip.lockMinutes)
        }
    }

    private func startEnforcement(devices: Set<InputDevice>, reason: String, lockMinutes: Int) {
        guard MacInputBlocker.isTrusted else {
            hasAccessibilityPermission = false
            return
        }
        engine.request(
            devices: devices, reason: reason,
            lockSeconds: TimeInterval(max(1, lockMinutes) * 60),
            warningSeconds: TimeInterval(settings.mistressRules.warningMinutes * 60),
            now: Date()
        )
        syncEnforcement()
    }

    /// Brings the overlay and input blocker in line with the engine's current state.
    private func syncEnforcement() {
        enforcements = engine.active
        let locked = engine.lockedDevices
        if locked != blockedDevices {
            blockedDevices = locked
            if locked.isEmpty {
                blocker.unblock()
            } else if !blocker.block(locked, allowPointerMovement: settings.mistressRules.safeWordEnabled) {
                // Couldn't block (Accessibility permission lost); skip these lockouts.
                hasAccessibilityPermission = false
                blockedDevices = []
                engine.endAllLocks()
                enforcements = engine.active
            }
        }
        if enforcements.isEmpty { overlay.hide() } else { overlay.show(model: self, count: enforcements.count) }
    }

    /// "Just 5 more minutes" for one warning.
    func extendWarning(_ id: Int) {
        if engine.extendWarning(id: id, by: 5 * 60) { syncEnforcement() }
    }

    /// The safe word: ends one running lockout early.
    func endLockout(_ id: Int) {
        guard settings.mistressRules.safeWordEnabled else { return }
        if engine.endLock(id: id) { syncEnforcement() }
    }

    func setMistress(_ enabled: Bool) {
        updateSettings { $0.mistressEnabled = enabled }
        if enabled {
            if !MacInputBlocker.isTrusted { MacInputBlocker.requestTrust() }
        } else {
            engine.cancelAll()
            lockouts.reset()
            syncEnforcement()
        }
    }

    func requestAccessibilityPermission() {
        MacInputBlocker.requestTrust()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshNotificationStatus() {
        notifier.checkAllowed { [weak self] allowed in
            Task { @MainActor in
                if self?.notificationsAllowed != allowed { self?.notificationsAllowed = allowed }
            }
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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
            if enabled { $0.unitsLastChecked = nil; $0.quipsLastChecked = nil }
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
