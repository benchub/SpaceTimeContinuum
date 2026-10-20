# Linux front end (early)

So far this is `stcd`, a headless recorder with a small command-line interface. It records to the same SQLite schema as the Mac app and sends Nanny break and stretch reminders as desktop notifications. There's no tray icon, graphs window, Mistress Mode, leaderboard or New Entropy yet.

## Build

Swift is only needed to build `stcd`, not to run it. Install it with [swiftly](https://www.swift.org/install/linux/):

```sh
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
./swiftly init    # accept its offer to install the system packages Swift needs
```

Open a new terminal (or `source` the file `init` names), check with `swift --version`, then:

```sh
sudo apt install build-essential libsqlite3-dev libnotify-bin
cd linux && swift build -c release --static-swift-stdlib
```

If linking fails with `cannot find crtbeginS.o` or `cannot find -lgcc`, Swift picked the newest GCC under `/usr/lib/gcc/<arch>-linux-gnu/` and that version's dev files aren't installed. Install the ones matching the highest number there, e.g. `sudo apt install libgcc-14-dev libstdc++-14-dev`.

`--static-swift-stdlib` puts the Swift runtime and Foundation inside the binary, so you can copy `.build/release/stcd` to a machine without Swift. A build without it needs the Swift libraries on whatever machine runs it.

## Run-time requirements

- `libsqlite3-0`, `libcurl4` (Ubuntu installs both by default) and `libnotify-bin` for notifications
- Read access to `/dev/input` (see below)
- `shared/units.json` and `shared/keyboards.json`, found via `$STC_SHARED_DIR`, `../share/spacetimecontinuum` next to the binary, `/usr/share/spacetimecontinuum`, or the source tree it was built from

## Permissions

`stcd` reads `/dev/input/event*` directly. That works the same under X11 and Wayland, but you have to be in the `input` group:

```sh
sudo usermod -aG input $USER   # then log out and back in
```

## Use

```sh
.build/release/stcd run          # record (Ctrl-C writes the partial minute and exits)
.build/release/stcd status       # today and lifetime, in silly units
.build/release/stcd devices      # keyboards, their IDs and key travel
.build/release/stcd nanny on
.build/release/stcd stretch on 30
.build/release/stcd mouse-dpi 1600
.build/release/stcd autostart on # ~/.config/autostart entry
```

Data lives in `~/.local/share/SpaceTimeContinuum/spacetime.sqlite` (or `$STC_DATA_DIR`). Setting changes are picked up by a running `stcd run` within a minute, except `mouse-dpi`, which needs a restart.

## How it measures

- **Keys**: presses on any evdev device with letter keys, times that keyboard's travel (from `shared/keyboards.json` or `stcd travel`).
- **Pointer**: Wayland doesn't reveal the cursor position, so relative mice are measured as counts ÷ DPI. That's how far the mouse moved, not the cursor. Touchpads use their reported resolution. Absolute pointers without one, like a VM's USB tablet, assume the range spans a 1920-point-wide screen.
- **Screen on**: DPMS state of connected DRM connectors in `/sys/class/drm`.
- **Unlocked**: logind's `LockedHint` for the graphical session.

## Still to do

- **Tray**: StatusNotifierItem (GNOME needs the AppIndicator extension, which Ubuntu ships).
- **Windows**: configuration, graphs and conversion (GTK4).
- **Mistress Mode**: `EVIOCGRAB` the input devices plus a fullscreen window.
- **Leaderboard sync and New Entropy downloads** (the core already supports both).
