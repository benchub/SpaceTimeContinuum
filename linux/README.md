# Linux front end (planned)

Not implemented yet. The shared core (`../core`) already builds on Linux (`apt install libsqlite3-dev`).

A front end needs to implement the protocols in `core/Sources/STCCore/Platform/PlatformProtocols.swift`:

- **Input**: libinput / evdev (`/dev/input/event*`, requires the `input` group) for key presses per device and relative pointer motion.
- **Display geometry**: XRandR or the Wayland `wl_output` physical size.
- **Session state**: logind `LockedHint` / `IdleHint` over D-Bus; DPMS for screen on.
- **Tray**: StatusNotifierItem (AppIndicator).
- **Login item**: `~/.config/autostart/*.desktop`.
- **Notifications**: `org.freedesktop.Notifications`.
