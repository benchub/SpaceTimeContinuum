# Windows front end (planned)

Not implemented yet. The shared core (`../core`) is intended to build with the Swift toolchain for Windows (it bundles SQLite).

A front end needs to implement the protocols in `core/Sources/STCCore/Platform/PlatformProtocols.swift`:

- **Input**: Raw Input (`RegisterRawInputDevices` with `RIDEV_INPUTSINK`) to count key presses per device and measure pointer motion.
- **Display geometry**: `GetDpiForMonitor` plus EDID physical size.
- **Session state**: `WTSRegisterSessionNotification` (lock/unlock) and `GUID_CONSOLE_DISPLAY_STATE` power notifications.
- **Tray**: `Shell_NotifyIcon`.
- **Login item**: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
- **Notifications**: toast notifications.
