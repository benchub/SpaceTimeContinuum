import Foundation
import STCCore

let usage = """
    Usage: stcd <command>

      run                     Record keyboard and pointer activity (runs until stopped)
      status                  Show today's and lifetime totals
      devices                 List detected keyboards and their key travel
      nanny on|off            Turn break reminders on or off
      stretch on|off [MIN]    Turn stretch reminders on or off, optionally every MIN minutes
      travel KEYBOARD_ID MM   Set key travel for a keyboard (IDs come from `devices`)
      mouse-dpi DPI           Set your mouse's resolution (default 1000)
      autostart on|off        Start recording when you log in

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
    let on = onOff(args.dropFirst().first)
    daemon.updateSettings { $0.nannyEnabled = on }

case "stretch":
    let on = onOff(args.dropFirst().first)
    let minutes = args.count > 2 ? Int(args[2]) : nil
    daemon.updateSettings {
        $0.nannyRules.stretchEnabled = on
        if let minutes, minutes > 0 { $0.nannyRules.stretchEveryMinutes = minutes }
        if on { $0.nannyEnabled = true }
    }

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
