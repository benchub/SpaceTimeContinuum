import Foundation
import STCCore

let usage = """
    Usage: stcd <command>

      run                          Record activity; shows a tray icon when there's a display
      status                       Show today's and lifetime totals
      devices                      List detected keyboards and their key travel
      nanny on|off                 Break reminders
      stretch on|off [MIN]         Stretch reminders, optionally every MIN minutes
      mistress on|off              Enforce breaks by blocking input (needs Nanny or lockouts)
      lockout keyboard|mouse on|off [LOCK_MIN EVERY_MIN]
                                   Block a device for LOCK_MIN minutes after EVERY_MIN minutes of use
      warning MIN                  Minutes of warning before a block (0 for none)
      safeword on|off              Allow typing UNCLE to end a block early
      entropy on|off               Download new silly units and stretch quips daily
      leaderboard on|off           Upload minute totals to the leaderboard
      leaderboard name NAME        Claim a leaderboard name
      travel KEYBOARD_ID MM        Set key travel for a keyboard (IDs come from `devices`)
      mouse-dpi DPI                Set your mouse's resolution (default 1000)
      autostart on|off             Start recording when you log in
      updates on|off               Check daily for a newer release (default on)
      version                      Show the version

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func onOff(_ arg: String?) -> Bool {
    switch arg {
    case "on": return true
    case "off": return false
    default: fail(usage)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let daemon: Daemon
do { daemon = try Daemon() } catch { fail("Couldn't open the database: \(error)") }

switch args.first {
case "run":
    daemon.run()

case "status", nil:
    print(daemon.summary())

case "devices":
    guard daemon.input.hasPermission else { daemon.input.requestPermission(); exit(1) }
    try? daemon.input.start()
    let keyboards = daemon.input.keyboards
    daemon.input.stop()
    if keyboards.isEmpty { print("No keyboards found.") }
    for k in keyboards {
        let mm = daemon.settings.travelMM(for: k, catalog: daemon.keyboardCatalog)
        print("\(k.productName)\(k.isBuiltIn ? " (built-in)" : "")\n  id: \(k.id)\n  travel: \(mm) mm")
    }
    print("Mouse DPI: \(Int(daemon.input.mouseDPI))")

case "nanny":
    daemon.setNanny(onOff(args.dropFirst().first))

case "stretch":
    let on = onOff(args.dropFirst().first)
    let minutes = args.count > 2 ? Int(args[2]) : nil
    daemon.updateSettings {
        $0.nannyRules.stretchEnabled = on
        if let minutes, minutes > 0 { $0.nannyRules.stretchEveryMinutes = minutes }
        if on { $0.nannyEnabled = true }
    }

case "mistress":
    daemon.setMistress(onOff(args.dropFirst().first))

case "lockout":
    guard args.count == 3 || args.count == 5, ["keyboard", "mouse"].contains(args[1]) else { fail(usage) }
    let on = onOff(args[2])
    var times: (lock: Int, every: Int)?
    if args.count == 5 {
        guard let lock = Int(args[3]), let every = Int(args[4]), lock > 0, every > 0 else { fail(usage) }
        times = (lock, every)
    }
    daemon.updateSettings {
        if args[1] == "keyboard" {
            $0.mistressRules.keyboardLockEnabled = on
            if let times { $0.mistressRules.keyboardLockMinutes = times.lock; $0.mistressRules.keyboardEveryMinutes = times.every }
        } else {
            $0.mistressRules.mouseLockEnabled = on
            if let times { $0.mistressRules.mouseLockMinutes = times.lock; $0.mistressRules.mouseEveryMinutes = times.every }
        }
        if on { $0.mistressEnabled = true }
    }

case "warning":
    guard args.count == 2, let minutes = Int(args[1]), minutes >= 0 else { fail(usage) }
    daemon.updateSettings { $0.mistressRules.warningMinutes = minutes }

case "safeword":
    let on = onOff(args.dropFirst().first)
    daemon.updateSettings { $0.mistressRules.safeWordEnabled = on }

case "entropy":
    daemon.setNewEntropy(onOff(args.dropFirst().first))

case "leaderboard" where args.count >= 3 && args[1] == "name":
    let name = LeaderboardName.normalize(args.dropFirst(2).joined(separator: " "))
    guard LeaderboardName.isValid(name) else { fail("That name isn't allowed. Use 3–50 letters, digits, spaces, dots, dashes or underscores, starting and ending with a letter or digit.") }
    let s = daemon.settings
    switch await daemon.client.claimName(guid: s.deviceGUID, token: s.deviceToken, name: name) {
    case .success(let claimed):
        daemon.updateSettings { $0.leaderboardName = claimed; $0.leaderboardEnabled = true }
        print("Your leaderboard name is now \(claimed).")
    case .unavailable(let taken):
        fail("Someone already has \(taken). Try another name.")
    case .error(let message):
        fail("Couldn't set the name: \(message)")
    }

case "leaderboard":
    daemon.setLeaderboardEnabled(onOff(args.dropFirst().first))

case "updates":
    let on = onOff(args.dropFirst().first)
    try? daemon.store.setSetting(Daemon.updateChecksKey, on ? nil : "off")

case "version":
    print("Space Time Continuum \(AppVersion.current)")

case "travel":
    guard args.count == 3, let mm = Double(args[2]), mm > 0, mm < 20 else { fail(usage) }
    daemon.updateSettings { $0.keyboardTravelMM[args[1]] = mm }

case "mouse-dpi":
    guard args.count == 2, let dpi = Double(args[1]), dpi > 0 else { fail(usage) }
    try? daemon.store.setSetting(Daemon.mouseDPIKey, String(dpi))

case "autostart":
    let on = onOff(args.dropFirst().first)
    do {
        try daemon.loginItem.setEnabled(on)
        daemon.updateSettings { $0.launchAtLogin = on }
    } catch {
        fail("Couldn't update autostart: \(error)")
    }

default:
    fail(usage)
}
