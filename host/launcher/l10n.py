#!/usr/bin/env python3
"""Launcher localization: String Catalogs (Localizable.xcstrings, InfoPlist.xcstrings) -> *.lproj.

  l10n.py sync DIR        merge the compiler's string extraction (DIR/*.stringsdata from
                          `swiftc -emit-localized-strings`, one per source file) into
                          Localizable.xcstrings: new keys are added, keys no longer in the
                          code are marked stale (xcstringstool sync, as Xcode does on build)
  l10n.py check [--strict]
                          every current key translated into every language, the same format
                          arguments (type per position) as the English key, no stale keys;
                          prints problems, exits 1 with --strict
  l10n.py compile DIR     DIR/<lang>.lproj/{Localizable,InfoPlist}.strings(dict) for the app
  l10n.py export LANG FILE
                          the keys LANG lacks (missing or not "translated") with their comments
                          as JSON [{key, comment}] for a translator
  l10n.py import LANG FILE
                          translations {key: "text"} or {key: {"plural": {"one": …, "other": …}}}
                          into Localizable.xcstrings as "translated"; keys the catalog no longer
                          has are skipped and listed

Keys are the English source text (SwiftUI literals, String(localized:)); strings without
letters (numbers, "%lld", "") need no translation. After import, build.sh's sync rewrites the
catalog in xcstringstool's own formatting.
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCES = HERE / "Sources/steamac-vm"
CATALOGS = [HERE / "Localizable.xcstrings", HERE / "InfoPlist.xcstrings"]
LANGUAGES = ["ru", "zh-Hans"]

SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])")


def args_of(text):
    """{position: conversion} of a printf-style format; %% ignored."""
    out, seq = {}, 0
    for m in SPEC.finditer(text):
        if m[3] == "%":
            continue
        seq += 1
        pos = int(m[1]) if m[1] else seq
        conv = m[3].lower()
        out[pos] = "d" if conv in "diu" else ("f" if conv in "feg" else conv)
    return out


def units(localization):
    """(variation path, stringUnit) for a localization entry, plural/device variations included."""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"]
    for kind, cases in localization.get("variations", {}).items():
        for case, entry in cases.items():
            for path, unit in units(entry):
                yield f"{kind}.{case}{'.' + path if path else ''}", unit


def needs_translation(key, entry):
    return entry.get("shouldTranslate", True) and re.search(r"[A-Za-z]{2}", SPEC.sub("", key))


def sync(directory):
    data = sorted(p for p in Path(directory).glob("*.stringsdata") if (SOURCES / (p.stem + ".swift")).exists())
    if not data:
        sys.exit(f"l10n.py: no .stringsdata for {SOURCES} in {directory}")
    run = lambda: subprocess.run(["xcrun", "xcstringstool", "sync", str(CATALOGS[0]), "--stringsdata", *map(str, data)],
                                 check=True)
    run()
    # Keys the code no longer uses go (with their translations; git keeps them), then
    # xcstringstool rewrites the file in its own formatting.
    catalog = json.loads(CATALOGS[0].read_text())
    stale = [k for k, e in catalog["strings"].items() if e.get("extractionState") == "stale"]
    if stale:
        for k in stale:
            del catalog["strings"][k]
        CATALOGS[0].write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
        run()
        print(f"l10n: removed {len(stale)} key(s) no longer in the code: {stale}")


def check(strict):
    problems = []
    for catalog in CATALOGS:
        strings = json.loads(catalog.read_text())["strings"]
        for key, entry in strings.items():
            if entry.get("extractionState") == "stale":
                problems.append(f"{catalog.name}: stale (no longer in the code): {key!r}")
                continue
            if not needs_translation(key, entry):
                continue
            source = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", key)
            want = args_of(source)
            for lang in LANGUAGES:
                loc = entry.get("localizations", {}).get(lang)
                if not loc:
                    problems.append(f"{catalog.name}: {lang} missing: {key!r}")
                    continue
                for path, unit in units(loc):
                    where = f"{lang}{'/' + path if path else ''}"
                    if unit.get("state") != "translated":
                        problems.append(f"{catalog.name}: {where} {unit.get('state')}: {key!r}")
                    got = args_of(unit.get("value", ""))
                    # A plural case may drop the count ("one" -> "a minute"), never change types/positions.
                    if any(want.get(p) != t for p, t in got.items()) or (not path and got != want):
                        problems.append(f"{catalog.name}: {where} format arguments {got} != {want}: {key!r}")
    for p in problems:
        print("l10n: " + p, file=sys.stderr)
    if problems:
        print(f"l10n: {len(problems)} problem(s) in {', '.join(c.name for c in CATALOGS)}", file=sys.stderr)
        if strict:
            sys.exit(1)
    else:
        print(f"l10n: {', '.join(LANGUAGES)} complete")


def compile_(directory):
    out = Path(directory)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    for catalog in CATALOGS:
        subprocess.run(["xcrun", "xcstringstool", "compile", str(catalog), "--output-directory", str(out)], check=True)
    # Base language too, so English is an explicit localization of the bundle.
    (out / "en.lproj").mkdir(exist_ok=True)


def translated(entry, lang):
    loc = entry.get("localizations", {}).get(lang)
    return bool(loc) and all(u.get("state") == "translated" for _, u in units(loc))


def export(lang, path):
    strings = json.loads(CATALOGS[0].read_text())["strings"]
    todo = [{"key": k, "comment": e.get("comment", "")} for k, e in strings.items()
            if e.get("extractionState") != "stale" and needs_translation(k, e) and not translated(e, lang)]
    Path(path).write_text(json.dumps(todo, ensure_ascii=False, indent=1) + "\n")
    print(f"l10n: {len(todo)} key(s) for {lang} -> {path}")


def import_(lang, path):
    catalog = json.loads(CATALOGS[0].read_text())
    strings = catalog["strings"]
    unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
    new = json.loads(Path(path).read_text())
    unknown = [k for k in new if k not in strings]
    if unknown:
        print(f"l10n: skipped, not in {CATALOGS[0].name}: {unknown}", file=sys.stderr)
    new = {k: v for k, v in new.items() if k in strings}
    for key, value in new.items():
        loc = unit(value) if isinstance(value, str) else \
            {"variations": {"plural": {case: unit(v) for case, v in value["plural"].items()}}}
        strings[key].setdefault("localizations", {})[lang] = loc
    CATALOGS[0].write_text(json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "),
                                      sort_keys=True) + "\n")
    print(f"l10n: {len(new)} {lang} translation(s) imported")


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "sync":
        sync(sys.argv[2])
    elif len(sys.argv) >= 2 and sys.argv[1] == "check":
        check("--strict" in sys.argv[2:])
    elif len(sys.argv) >= 3 and sys.argv[1] == "compile":
        compile_(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "export":
        export(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 4 and sys.argv[1] == "import":
        import_(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
