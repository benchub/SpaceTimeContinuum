# Silly Units Format

Silly units are served from `GET https://spacetime.silentmedia.com/units` and bundled with
the app as [`shared/units.json`](../shared/units.json). Both use the same format:

```json
{
  "time": [
    [300, "boil water"],
    [7000, "flight from pdx to lax"]
  ],
  "space": [
    [3, "a yard"],
    [12123, "a 10 story building"]
  ]
}
```

- `time`: list of `[seconds, label]` or `[seconds, label, plural]` entries.
- `space`: list of `[meters, label]` or `[meters, label, plural]` entries.
- `plural` (optional) is the plural form of `label` (e.g. `"cup of coffee"` →
  `"cups of coffee"`). When absent, the app pluralizes the last word using simple English
  rules (`bus` → `buses`, `body` → `bodies`, `foot` → `feet`, …).
- Values must be finite numbers `> 0`. Labels must be non-empty strings of at most 120
  characters.
- Labels are written as singular noun phrases that make sense after a quantity, e.g.
  `"human hair width"`, `"New York to London flight"`. The app adds the quantity and
  plural, e.g. "about 3.5 New York to London flights". A leading article
  (`a `, `an `, `the `) is removed when a quantity is shown.
- Unknown top-level keys are ignored (room for future extensions).
- A downloaded list **replaces** the bundled list completely. It is accepted only if it
  parses and contains at least 10 valid `time` entries and 10 valid `space` entries;
  otherwise it is ignored.
