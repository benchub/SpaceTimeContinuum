#!/usr/bin/env python3
"""Validate shared/units.json, shared/quips.json and shared/keyboards.json.

Usage: python3 shared/validate_data.py [--show-plurals]
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UNITS_PATH = os.path.join(HERE, "units.json")
KEYBOARDS_PATH = os.path.join(HERE, "keyboards.json")
QUIPS_PATH = os.path.join(HERE, "quips.json")

MIN_QUIPS = 30
MAX_QUIP = 200

MIN_UNITS = 300
MAX_LABEL = 60
MIN_RATIO, MAX_RATIO = 1.0, 200.0
COVERAGE = {"time": (1.0, 3e7), "space": (1e-5, 1e8)}

IRREGULAR = {
    "foot": "feet", "tooth": "teeth", "mouse": "mice", "person": "people",
    "child": "children", "man": "men", "woman": "women", "leaf": "leaves",
    "knife": "knives", "life": "lives", "loaf": "loaves", "half": "halves",
    "goose": "geese",
}
UNCHANGED = {"sheep", "deer", "fish", "series", "species", "aircraft"}
O_ES = {"potato", "tomato", "hero", "echo", "torpedo", "volcano"}


def pluralize_word(word):
    """Mirror of the app's default rule for pluralizing the last word."""
    lower = word.lower()
    if lower in UNCHANGED:
        return word
    if lower in IRREGULAR:
        plural = IRREGULAR[lower]
        return plural[0].upper() + plural[1:] if word[:1].isupper() else plural
    if lower in O_ES:
        return word + "es"
    if lower.endswith(("s", "x", "z", "ch", "sh")):
        return word + "es"
    if len(lower) >= 2 and lower.endswith("y") and lower[-2] not in "aeiou":
        return word[:-1] + "ies"
    return word + "s"


def default_plural(label):
    head, sep, last = label.rpartition(" ")
    return head + sep + pluralize_word(last)


def check_units(errors, show_plurals):
    with open(UNITS_PATH, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        errors.append("units.json: top level must be an object")
        return
    for kind in ("time", "space"):
        entries = data.get(kind)
        if not isinstance(entries, list):
            errors.append(f"units.json: '{kind}' must be a list")
            continue
        if len(entries) < MIN_UNITS:
            errors.append(f"units.json: {kind} has {len(entries)} entries, need >= {MIN_UNITS}")
        seen = set()
        values = []
        for i, entry in enumerate(entries):
            where = f"units.json {kind}[{i}]"
            if not isinstance(entry, list) or len(entry) not in (2, 3):
                errors.append(f"{where}: must be [value, label] or [value, label, plural]")
                continue
            value, label = entry[0], entry[1]
            if isinstance(value, bool) or not isinstance(value, (int, float)) \
                    or not math.isfinite(value) or value <= 0:
                errors.append(f"{where}: value must be a finite number > 0")
                continue
            if not isinstance(label, str) or not label.strip() or label != label.strip():
                errors.append(f"{where}: label must be a non-empty trimmed string")
                continue
            if len(label) > MAX_LABEL:
                errors.append(f"{where}: label longer than {MAX_LABEL} chars: {label!r}")
            if label.lower().startswith(("a ", "an ", "the ")):
                errors.append(f"{where}: label has a leading article: {label!r}")
            if label.lower() in seen:
                errors.append(f"{where}: duplicate label {label!r}")
            seen.add(label.lower())
            plural = default_plural(label)
            if len(entry) == 3:
                if not isinstance(entry[2], str) or not entry[2].strip():
                    errors.append(f"{where}: plural must be a non-empty string")
                    continue
                if entry[2] == plural:
                    errors.append(f"{where}: explicit plural equals default, omit it: {label!r}")
                plural = entry[2]
            if show_plurals:
                print(f"{kind:5} {value:>14g}  {label}  ->  {plural}")
            values.append(value)
        if values != sorted(values):
            errors.append(f"units.json: {kind} is not sorted ascending by value")
        lo, hi = COVERAGE[kind]
        gaps = []
        step = 10 ** 0.25
        n = round(math.log10(hi / lo) / math.log10(step))
        for k in range(n + 1):
            test = lo * step ** k
            if not any(MIN_RATIO <= test / v <= MAX_RATIO for v in values):
                gaps.append(test)
        if gaps:
            errors.append(f"units.json: {kind} coverage gaps at " + ", ".join(f"{g:g}" for g in gaps))
        print(f"units.json: {kind}: {len(entries)} entries, coverage {lo:g}..{hi:g} "
              f"({n + 1} test points): {'OK' if not gaps else f'{len(gaps)} gaps'}")


def check_quips(errors):
    with open(QUIPS_PATH, encoding="utf-8") as f:
        data = json.load(f)
    quips = data.get("stretch") if isinstance(data, dict) else None
    if not isinstance(quips, list):
        errors.append("quips.json: must be an object with a 'stretch' list")
        return
    if len(quips) < MIN_QUIPS:
        errors.append(f"quips.json: {len(quips)} stretch quips, need >= {MIN_QUIPS}")
    seen = set()
    for i, q in enumerate(quips):
        where = f"quips.json stretch[{i}]"
        if not isinstance(q, str) or not q.strip() or q != q.strip():
            errors.append(f"{where}: must be a non-empty trimmed string")
            continue
        if len(q) > MAX_QUIP:
            errors.append(f"{where}: longer than {MAX_QUIP} chars")
        if q.lower() in seen:
            errors.append(f"{where}: duplicate {q!r}")
        seen.add(q.lower())
    print(f"quips.json: {len(quips)} stretch quips")


def check_keyboards(errors):
    with open(KEYBOARDS_PATH, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or data.get("version") != 1:
        errors.append("keyboards.json: must be an object with version 1")
        return
    defaults = data.get("defaults")
    for key in ("builtin_laptop_mm", "mechanical_mm", "unknown_external_mm"):
        v = defaults.get(key) if isinstance(defaults, dict) else None
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 < v < 10:
            errors.append(f"keyboards.json: defaults.{key} must be a number in (0, 10)")
    boards = data.get("keyboards")
    if not isinstance(boards, list):
        errors.append("keyboards.json: 'keyboards' must be a list")
        return
    allowed = {"name", "vendor_id", "product_ids", "name_patterns", "travel_mm", "switch"}
    names = set()
    signatures = []
    for i, kb in enumerate(boards):
        where = f"keyboards.json keyboards[{i}]"
        if not isinstance(kb, dict):
            errors.append(f"{where}: must be an object")
            continue
        extra = set(kb) - allowed
        if extra:
            errors.append(f"{where}: unknown keys {sorted(extra)}")
        name = kb.get("name")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{where}: name must be a non-empty string")
        elif name in names:
            errors.append(f"{where}: duplicate name {name!r}")
        names.add(name)
        vid = kb.get("vendor_id")
        if vid is not None and (isinstance(vid, bool) or not isinstance(vid, int) or not 0 < vid <= 0xFFFF):
            errors.append(f"{where}: vendor_id must be an int in 1..65535")
        pids = kb.get("product_ids")
        if pids is not None and (not isinstance(pids, list) or not pids or not all(
                isinstance(p, int) and not isinstance(p, bool) and 0 <= p <= 0xFFFF for p in pids)):
            errors.append(f"{where}: product_ids must be a non-empty list of ints in 0..65535")
        pats = kb.get("name_patterns")
        if not isinstance(pats, list) or not all(isinstance(p, str) and p.strip() for p in pats):
            errors.append(f"{where}: name_patterns must be a list of non-empty strings")
            continue
        if any(p != p.lower() for p in pats):
            errors.append(f"{where}: name_patterns should be lowercase")
        if vid is None and not pats and pids is None:
            errors.append(f"{where}: entry would match every keyboard")
        travel = kb.get("travel_mm")
        if isinstance(travel, bool) or not isinstance(travel, (int, float)) or not 0 < travel < 10:
            errors.append(f"{where}: travel_mm must be a number in (0, 10)")
        if "switch" in kb and (not isinstance(kb["switch"], str) or not kb["switch"].strip()):
            errors.append(f"{where}: switch must be a non-empty string")
        # An earlier entry that is at least as general shadows this one entirely.
        for j, (svid, spids, spats) in enumerate(signatures):
            if (svid is None or svid == vid) and (spids is None or (pids is not None and set(pids) <= spids)) \
                    and all(any(sp in p for p in pats) for sp in spats):
                errors.append(f"{where} ({name}): unreachable, shadowed by keyboards[{j}]")
                break
        signatures.append((vid, set(pids) if pids else None, [p.lower() for p in pats]))
    print(f"keyboards.json: {len(boards)} entries")
    if len(boards) < 80:
        errors.append(f"keyboards.json: only {len(boards)} entries, need >= 80")


def main():
    errors = []
    check_units(errors, "--show-plurals" in sys.argv)
    check_quips(errors)
    check_keyboards(errors)
    if errors:
        for e in errors:
            print("ERROR:", e)
        print(f"FAILED with {len(errors)} error(s)")
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
