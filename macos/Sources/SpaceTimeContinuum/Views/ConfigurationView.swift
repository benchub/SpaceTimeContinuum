import STCCore
import SwiftUI

struct ConfigurationView: View {
    @ObservedObject var model: AppModel
    var onDone: () -> Void

    @State private var leaderboardName = ""
    @State private var resetArmed = false
    @State private var resetDone = false

    private let leaderboardTip = "If you join the leadboard, your time and distance data will be sent to a server along with your username and IP address, which very roughly and possibly incorrectly puts you on a map. You also get to see yourself on the leaderboard. Requires you to give yourself a leaderboard name."

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if model.isFirstRun {
                    Section {
                        Text("Welcome to Space Time Continuum! It measures how much time you spend using your keyboard and mouse, and how far they travel, in units of questionable scientific value.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.hasInputPermission { permissionSection }
                keyboardSection
                Section("Startup") {
                    Toggle("Start Space Time Continuum when I log in", isOn: Binding(
                        get: { model.settings.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    if let err = model.loginItemError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                leaderboardSection
                Section("Extras") {
                    Toggle("Nanny Mode", isOn: Binding(get: { model.settings.nannyEnabled }, set: { model.setNanny($0) }))
                        .help("Provide helpful hints to take breaks.")
                    Toggle("New Entropy", isOn: Binding(get: { model.settings.newEntropyEnabled }, set: { model.setNewEntropy($0) }))
                        .help("Periodically download new ways to measure things.")
                }
                Section("History") { resetButton }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 500, minHeight: 560)
        .onAppear { leaderboardName = model.settings.leaderboardName }
    }

    // MARK: Sections

    private var permissionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Input Monitoring permission needed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text("Space Time Continuum only counts key presses and measures pointer movement; it never records which keys you press. macOS still requires the Input Monitoring permission for this. Enable Space Time Continuum in System Settings → Privacy & Security → Input Monitoring.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") {
                    model.requestInputPermission()
                    model.openInputMonitoringSettings()
                }
            }
        }
    }

    private var keyboardSection: some View {
        Section {
            if model.keyboards.isEmpty {
                Text(model.hasInputPermission ? "No keyboards detected." : "Keyboards will be detected once permission is granted.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.keyboards) { kb in
                KeyboardTravelRow(model: model, keyboard: kb)
            }
        } header: {
            Text("Key travel")
        } footer: {
            Text("How far do your keys move when pressed? For reference, laptop keyboards tend to travel about 1 mm and mechanical keyboards about 3 mm or more. Each keyboard is tracked separately, so an external keyboard gets its own setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var leaderboardSection: some View {
        let available = Features.leaderboardAvailable
        return Section {
            Toggle("Join the leaderboard", isOn: Binding(
                get: { model.settings.leaderboardEnabled },
                set: { model.setLeaderboardEnabled($0) }
            ))
            .disabled(!available || model.settings.leaderboardName.isEmpty)
            .help(leaderboardTip)

            HStack {
                TextField("Leaderboard name", text: $leaderboardName)
                    .disabled(!available)
                    .onChange(of: leaderboardName) { _, new in model.leaderboardNameEdited(new) }
                Button("Set name") { model.claimLeaderboardName(leaderboardName) }
                    .disabled(!available || model.nameState != .available
                        || LeaderboardName.normalize(leaderboardName) == model.settings.leaderboardName)
            }
            nameStatus
        } header: {
            Text("Leaderboard")
        } footer: {
            if !available {
                Text("The leaderboard is coming in a future version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var nameStatus: some View {
        if let msg = model.nameClaimMessage {
            Text(msg.text).font(.caption).foregroundStyle(msg.success ? .green : .red)
        } else {
            switch model.nameState {
            case .idle: EmptyView()
            case .checking: Text("Checking…").font(.caption).foregroundStyle(.secondary)
            case .available: Text("Available").font(.caption).foregroundStyle(.green)
            case .unavailable(let reason):
                Text(reason == "reserved" ? "Unavailable (reserved)" : "Unavailable").font(.caption).foregroundStyle(.red)
            case .invalid:
                Text("3–24 letters, digits, spaces, _ - or . (start and end with a letter or digit)")
                    .font(.caption).foregroundStyle(.red)
            case .error(let e): Text(e).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var resetButton: some View {
        HStack {
            if resetArmed {
                Button {
                    model.resetHistory()
                    resetArmed = false
                    resetDone = true
                    leaderboardName = ""
                } label: {
                    Text("Are you sure? Cannot be undone!").bold()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Cancel") { resetArmed = false }
            } else {
                Button("Reset tracking history") {
                    resetDone = false
                    resetArmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { resetArmed = false }
                }
            }
            Spacer()
            if resetDone {
                Text("All time and distance reset to 0.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: resetArmed)
    }
}

private struct KeyboardTravelRow: View {
    @ObservedObject var model: AppModel
    let keyboard: KeyboardDevice

    private var sourceText: String {
        if model.settings.keyboardTravelMM[keyboard.id] != nil { return "Your setting" }
        switch model.keyboardCatalog.suggestion(for: keyboard).source {
        case .database(let name): return "Recognized as \(name)"
        case .builtInDefault: return "Built-in keyboard (typical laptop travel)"
        case .unknownDefault: return "Unknown keyboard: please check its travel"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: keyboard.isBuiltIn ? "laptopcomputer" : "keyboard")
                    Text(keyboard.productName)
                }
                Text(sourceText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("", value: Binding(
                get: { model.travelMM(for: keyboard) },
                set: { model.setTravelMM($0, for: keyboard) }
            ), format: .number.precision(.fractionLength(1)))
                .multilineTextAlignment(.trailing)
                .frame(width: 50)
            Stepper("", value: Binding(
                get: { model.travelMM(for: keyboard) },
                set: { model.setTravelMM(($0 * 10).rounded() / 10, for: keyboard) }
            ), in: 0.1...10, step: 0.1)
                .labelsHidden()
            Text("mm")
        }
    }
}
