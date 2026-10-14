# Space Time Continuum

One day my physical therapist asked me how much time I spend on my mouse vs. my keyboard. I didn't know, but I knew I could make an app that could tell me. Then a fever dream turned that simple idea into Space Time Continuum.

**Behold!** It is now easy to:

* Keep track of how much time you are using your keyboard vs your mouse/trackball/whatever.
* Keep track of how your recent activity compares with past activity.
* Get nanny reminders when it's time to go enjoy life for a few minutes away from your computer (if you want).
* Easily measure the distance things have moved over time, in whatever silly unit makes the most sense to Space Time Continuum's algorithm.
* Join a leaderboard of dubious distinction.

Space Time Continuum sits in your menu bar and tracks how much you use your input devices. Of course it does not track what you are actually typing or pointing at, just how often you smash your keys or wave your pointer around.

macOS is supported today. The code is laid out so Linux and Windows front ends can share the same core. Pull requests welcome.

## What it measures

Each second it records:

- **Pointer travel**: on-screen movement converted to physical distance using each display's reported size and pixel density. A move across displays with different densities is scaled by the average of the two.
- **Key presses**: counted only, never logged. Distance is presses × the key travel of the keyboard that was pressed. Travel is set per keyboard in Configuration, and known keyboards are pre-filled from [`shared/keyboards.json`](shared/keyboards.json).
- Whether the **screen was on** and whether the session was **unlocked**.

At the start of every minute the previous 60 seconds are rolled up into one row in a local SQLite database. Running totals and graph caches are updated in the same transaction. Only minute rollups are stored. Per-second data is never kept beyond the current minute.

The database is `~/Library/Application Support/SpaceTimeContinuum/spacetime.sqlite`.

## Features

- **Menu bar**: today's keyboard and mouse time, plus lifetime distance, in silly units. Hover a line to see real units.
- **Time Graphs**: Today, This week or This month, compared against yesterday, last week, last month, or a typical weekday, weekend or period.
- **Nanny Mode** (opt-in): suggests a break when you've been active for at least 48 of the last 60 minutes, or unlocked with the screen on for the last two hours.
- **New Entropy**: downloads fresh silly units from `https://spacetime.silentmedia.com/units` once a day.
- **Leaderboard** (opt-in): If you want to brag about your usage to other addicts, you can.

## Building (macOS 14+)

Requires Xcode 15 or later (Swift 5.10+).

```sh
cd core && swift test          # cross-platform core + tests
cd ../macos && scripts/build-app.sh
open "build/Space Time Continuum.app"
```

On first launch, grant **Input Monitoring** permission (System Settings → Privacy & Security → Input Monitoring), then relaunch if prompted.

> macOS ties that permission to the app's code signature. Ad-hoc builds (the default) may need permission re-granted after each rebuild. To avoid that, sign with a stable identity:
> 1. Open up Keychain Access
> 2. Go to Keychain Access -> Certificate Assistant -> Create a Certificate...
> 3. Make a Code Signing certificate with a self-signed root. Call it whatever you want.
> 4. Assuming you called your certificate "Space Time Continuum", build it like:
> `SIGN_IDENTITY="Space Time Continuum" scripts/build-app.sh`

For quick iteration you can also run `swift run` from `macos/`. The permission then attaches to your terminal app. Set `STC_DATA_DIR=/some/dir` to use a throwaway database instead of the real one.

## Layout

```
core/      Cross-platform Swift package (STCCore): aggregation, SQLite storage,
           silly units, graphs, nanny, leaderboard client. No AppKit.
macos/     macOS menu bar app (AppKit + SwiftUI), built with SwiftPM.
linux/     Placeholder for a future Linux front end.
windows/   Placeholder for a future Windows front end.
shared/    Data shared by all platforms: units.json, keyboards.json.
docs/      Protocol spec, units format, architecture notes.
```

See [`docs/architecture.md`](docs/architecture.md) for details.

## Contributing data

Silly units and keyboard travel distances live in [`shared/`](shared/). Run `python3 shared/validate_data.py` after editing. The format is described in [`docs/units-format.md`](docs/units-format.md).

## License

MIT. The leaderboard server is a separate, private project.
