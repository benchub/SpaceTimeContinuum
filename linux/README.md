# Linux front end (early)

`stcd` records keyboard and pointer activity to the same SQLite schema as the Mac app. It shows a top-bar icon with the same menu as the Mac app (Time Today, Distance since…, a Leaderboard Settings window, and the main toggles), sends Nanny break and stretch reminders as desktop notifications, enforces breaks in Mistress Mode, uploads to the leaderboard and fetches New Entropy. Detailed settings are command-line only for now, and there's no graphs or conversion window yet. Without a display (e.g. over SSH) it runs headless.

## Build

Swift is only needed to build `stcd`, not to run it. Install it with [swiftly](https://www.swift.org/install/linux/):

```sh
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
./swiftly init    # accept its offer to install the system packages Swift needs
```

Open a new terminal (or `source` the file `init` names), check with `swift --version`, then:

```sh
sudo apt install build-essential libsqlite3-dev libcurl4-openssl-dev libnotify-bin libgtk-3-dev libayatana-appindicator3-dev
cd linux && swift build -c release --static-swift-stdlib
```

SwiftPM prints a long `prohibited flag(s): -pthread` warning: GLib's pkg-config flags include `-pthread` and SwiftPM drops it. That's harmless, since Swift links pthreads anyway.

If linking fails with `cannot find crtbeginS.o` or `cannot find -lgcc`, Swift picked the newest GCC under `/usr/lib/gcc/<arch>-linux-gnu/` and that version's dev files aren't installed. Install the ones matching the highest number there, e.g. `sudo apt install libgcc-14-dev libstdc++-14-dev`.

`--static-swift-stdlib` puts the Swift runtime and Foundation inside the binary, so you can copy `.build/release/stcd` to a machine without Swift. A build without it needs the Swift libraries on whatever machine runs it.

## Run-time requirements

- `libsqlite3-0`, `libcurl4` and `libgtk-3-0` (Ubuntu desktop installs these by default), `libayatana-appindicator3-1` for the top-bar icon, and `libnotify-bin` for notifications
- Read access to `/dev/input` (see below)
- `shared/units.json`, `shared/keyboards.json` and `shared/icon.jpg`, found via `$STC_SHARED_DIR`, `../share/spacetimecontinuum` next to the binary, `/usr/share/spacetimecontinuum`, or the source tree it was built from

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
.build/release/stcd leaderboard name "Wrist Destroyer"
```

Run `stcd` with no recognized command for the full list. Silly units in the menu are re-rolled each time it opens, and stay put while it's open.

The top-bar icon needs a StatusNotifierItem host. KDE has one built in. On GNOME it's the AppIndicator extension, which Ubuntu enables by default; on other distributions install `gnome-shell-extension-appindicator`.

### Mistress Mode

```sh
stcd mistress on                     # Nanny's break suggestions become 5-minute blocks
stcd lockout keyboard on 5 60        # block the keyboard 5 minutes for every 60 used
stcd lockout mouse on 5 60
stcd warning 2                       # minutes of countdown before a block
stcd safeword on                     # type UNCLE during a block to end it
```

Blocking uses `EVIOCGRAB`, so the desktop stops seeing the device while `stcd` keeps reading it. That's how the safe word still works with the keyboard blocked. A keyboard is only grabbed once no keys are held, so a held key can't get stuck repeating. If `stcd` exits or crashes, the kernel releases the grab. Unlike on macOS, a blocked mouse can't move at all, so the countdown's buttons only work while the mouse is free.

The countdown window sits at the top center of the primary monitor, above other windows. Wayland doesn't allow either, so `stcd` runs its windows through XWayland (X11), which Ubuntu's GNOME and KDE sessions include.

If `stcd warning 0` is set, blocks start without a warning, so there's no countdown and no "Just 5 more minutes" button.

Data lives in `~/.local/share/SpaceTimeContinuum/spacetime.sqlite` (or `$STC_DATA_DIR`). Setting changes are picked up by a running `stcd run` within a minute, except `mouse-dpi`, which needs a restart.

## How it measures

- **Keys**: presses on any evdev device with letter keys, times that keyboard's travel (from `shared/keyboards.json` or `stcd travel`).
- **Pointer**: Wayland doesn't reveal the cursor position, so relative mice are measured as counts ÷ DPI. That's how far the mouse moved, not the cursor. Touchpads use their reported resolution. Absolute pointers without one, like a VM's USB tablet, assume the range spans a 1920-point-wide screen.
- **Screen on**: DPMS state of connected DRM connectors in `/sys/class/drm`.
- **Unlocked**: logind's `LockedHint` for the graphical session.

## Tests

Run the core's tests with `cd ../core && swift test`. In Docker on macOS, Linux XCTest sometimes hangs in its own teardown, even for a package of empty tests. That's a toolchain problem, not a test failure, so use a real Linux machine or VM for test runs.

## Still to do

- **Windows**: configuration, graphs and conversion.
