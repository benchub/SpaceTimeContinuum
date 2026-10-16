import AppKit

// AppKit's default tooltip delay is slow; value is in milliseconds.
UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)

    // Treat SIGTERM like Quit so the partial minute is flushed to the database.
    signal(SIGTERM, SIG_IGN)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler { NSApp.terminate(nil) }
    sigterm.resume()

    withExtendedLifetime((delegate, sigterm)) { app.run() }
}
