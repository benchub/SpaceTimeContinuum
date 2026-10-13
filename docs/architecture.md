# Architecture

## Layers

```
┌──────────────── platform front end (macos/, linux/, windows/) ───────────────┐
│ input sensing · session state · login item · notifications · menu · windows  │
└───────────────────────────────┬───────────────────────────────────────────────┘
                                │ protocols in STCCore/Platform
┌───────────────────────────────▼──── STCCore (core/) ─────────────────────────┐
│ Recorder ─► MinuteBuffer ─► MinuteRollup ─► ActivityStore (SQLite)            │
│ PointerOdometer · KeyboardCatalog · SillyFormatter/UnitCatalog · Nanny        │
│ GraphBuilder · LeaderboardClient · SyncService · UnitsUpdater                 │
└───────────────────────────────────────────────────────────────────────────────┘
```

STCCore depends only on Foundation and the system SQLite library, so it builds on Linux as well (`apt install libsqlite3-dev`). Each front end provides:

| Protocol | macOS implementation |
|---|---|
| `SessionStateProviding` (screen on, unlocked) | `CGSessionCopyCurrentDictionary`, display sleep notifications |
| key presses per keyboard device | `IOHIDManager` (keyboard usage page, key-down only) |
| pointer movement | listen-only `CGEventTap`, falling back to an `NSEvent` global monitor |
| display geometry | `CGDisplayBounds` + `CGDisplayScreenSize` |
| `LoginItemManaging` | `SMAppService.mainApp` |
| `Notifying` | `UNUserNotificationCenter` |

## Data flow

1. Input callbacks add to lock-protected counters in `Recorder`. Key presses add the travel distance for the keyboard that was pressed. Pointer moves add meters from `PointerOdometer`, which converts points to meters using the display under the pointer and ignores warps such as cursor teleports.
2. A 1 Hz timer calls `Recorder.tick()`. It closes the previous second into a `SecondSample` (key presses, key meters, pointer meters, screen on, unlocked) and appends it to `MinuteBuffer`.
3. When the minute changes, `MinuteBuffer` emits a `MinuteRollup`. `ActivityStore.record` then runs a single transaction that:
   - upserts the `minutes` row (merging if the minute was already written, e.g. after a flush on sleep);
   - applies the delta to `quarters` (15-minute local-time buckets for graphs), `days`, and the single-row `totals`.
4. The menu reads `totals` + today's `days` row + the live partial minute, so startup never scans history.

## Storage (schema v1)

| table | purpose |
|---|---|
| `minutes` | one row per minute (UTC epoch start) with all metrics + `uploaded_at` |
| `quarters` | 15-minute rollups keyed by UTC start, tagged with local date/weekday/slot at write time |
| `days` | local-date rollups for month views and "typical" averages |
| `totals` | lifetime sums + `tracking_since` |
| `settings` | key/value; app settings stored as JSON |

Local date and slot are recorded at write time, so graphs follow wall-clock time across DST changes and time-zone moves.

## Silly units

`SillyFormatter` picks a unit so that the multiple falls in the first range that has candidates:

1. 10–200×
2. 1–10×
3. 0.01–1×

It picks at random within that range. Multiples ≥ 20 are rounded to integers, ≥ 1 to one decimal place, and smaller ones to two. "Exactly" is used only when the value really is exact. The menu re-rolls on every open. Graph tooltips use a seeded RNG so a hovered value keeps the same phrasing.

## Graphs

`GraphBuilder` reads only `quarters` and `days`:

| period | bin size | number of bins | source table |
|---|---|---|---|
| Today | 15 minutes | 96 | `quarters` |
| This week | 6 hours | 28 | `quarters` (week starts on the user's locale first weekday) |
| This month | 1 day | — | `days` |

Overlays can show the previous period, or averages over past days that have data: weekdays (Mon–Fri), weekends, or all days. Today is excluded from the averages.

## Leaderboard

Implemented end to end but switched off via `Features.leaderboardAvailable`. `SyncService` uploads unsynced minute rows every 5 min ± 30 s while unlocked. `NameAvailabilityChecker` debounces name checks to at most one per second. See [`protocol.md`](protocol.md).
