#!/usr/bin/env python3
"""readlog.py -- structured read of the KenshiLua log.

WHY: every debugging cycle today started with hand-grepping this log, and that
went wrong twice -- once with a regex where `[SKILL]` was silently treated as a
character class (matching S/K/I/L), and once by missing that a script had
produced NO output at all. This does the same read the same way every time.

It answers the four questions that actually came up:
  1. Which scripts loaded, and did any produce zero output?
  2. What was the LAST line before the process died? (log-as-cursor: a crash
     names its own killer, because we print each risky call before making it.)
  3. What errors were raised?
  4. What did each system report? (catches, grants, xp, water state)

Usage:
    python tools/readlog.py               # newest log, summary
    python tools/readlog.py --tail 40     # last N lines, cleaned
    python tools/readlog.py --tag FISH    # everything from one system
    python tools/readlog.py --errors      # errors + the crash cursor only
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

LOGDIR = Path(r"D:\SteamLibrary\steamapps\common\Kenshi\mods\KenshiLua\plugin")
INITDIR = Path(r"D:\SteamLibrary\steamapps\common\Kenshi\mods\KenshiLua\scripts\init")

TS = re.compile(r"^\d{4}-\d{2}-\d{2} [\d:.]+ \[[A-Z]+\]\s*")
TAG = re.compile(r"\[([A-Z][A-Z0-9]*)\]")


def newest_log() -> Path | None:
    logs = sorted(LOGDIR.glob("KenshiLua_*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    return logs[0] if logs else None


def clean(line: str) -> str:
    return TS.sub("", line).rstrip()


def main() -> int:
    ap = argparse.ArgumentParser(description="structured KenshiLua log reader")
    ap.add_argument("--tail", type=int, default=0)
    ap.add_argument("--tag", default="")
    ap.add_argument("--errors", action="store_true")
    ap.add_argument("--log", default="")
    args = ap.parse_args()

    path = Path(args.log) if args.log else newest_log()
    if not path or not path.is_file():
        print("no log found", file=sys.stderr)
        return 2

    raw = path.read_text(encoding="utf-8", errors="replace").splitlines()
    lines = [clean(l) for l in raw if l.strip()]
    print(f"log: {path.name}   ({len(lines)} lines)\n")

    if args.tail:
        for l in lines[-args.tail:]:
            print(" ", l)
        return 0

    if args.tag:
        want = f"[{args.tag.upper()}]"
        hits = [l for l in lines if want in l]
        print(f"--- {want}: {len(hits)} lines ---")
        for l in hits:
            print(" ", l.split(want, 1)[-1].strip())
        return 0

    # ---- 1. scripts loaded, and which produced nothing ----
    loaded = [l.split("loaded ", 1)[-1] for l in lines if "ScriptLoader: loaded" in l]
    tags_seen = {m.group(1) for l in lines for m in [TAG.search(l)] if m}
    print(f"SCRIPTS LOADED ({len(loaded)}):")
    for s in loaded:
        print("   ", s)

    if INITDIR.is_dir():
        on_disk = sorted(p.name for p in INITDIR.glob("*.lua"))
        missing = [f for f in on_disk if not any(f in l for l in loaded)]
        if missing:
            print("  [!] on disk but NOT loaded:", ", ".join(missing))

    print(f"\nTAGS THAT PRODUCED OUTPUT: {', '.join(sorted(tags_seen)) or '(none)'}")
    # a script that loaded but never printed is the exact failure we hit
    for s in loaded:
        stem = Path(s).stem
        guess = {"10_fishing": "FISH", "19_fishing_skill": "SKILL",
                 "05_wsm": "WSM", "24_cooking": "COOK"}.get(stem)
        if guess and guess not in tags_seen:
            print(f"  [!] {s} loaded but produced NO [{guess}] output -- did the chunk run?")

    # ---- 2. errors ----
    errs = [l for l in lines if re.search(r"\berror\b|\bERROR\b|attempt to|bad argument", l)]
    print(f"\nERRORS ({len(errs)}):")
    for l in errs[-12:]:
        print("   ", l)

    # ---- 3. crash cursor: last risky line with no result after it ----
    print("\nLAST 6 LINES (crash cursor -- a hard crash stops here):")
    for l in lines[-6:]:
        print("   ", l)

    if args.errors:
        return 0

    # ---- 4. per-system summaries ----
    catches = [l for l in lines if "CAUGHT" in l]
    fails = [l for l in lines if "grant: FAILED" in l or "FAILED" in l]
    if catches:
        print(f"\nCATCHES ({len(catches)}), last 5:")
        for l in catches[-5:]:
            print("   ", l.split("[FISH]", 1)[-1].strip())
    if fails:
        print(f"\nFAILED GRANTS ({len(fails)}), last 5:")
        for l in fails[-5:]:
            print("   ", l.split("[FISH]", 1)[-1].strip())

    # duplicate-handler detector: two divergent tallies is the signature
    # A single script copy produces a MONOTONIC tally. Two copies keep separate
    # state, so the printed value jumps BACKWARD (we saw fish=17 then fish=6).
    # An increasing run like 2,3,4,5 is healthy -- an earlier version flagged it,
    # which is the crying-wolf failure a diagnostic tool must not have.
    tallies = re.findall(r"totals fish=(\d+) junk=(\d+)", "\n".join(lines))
    if len(tallies) >= 3:
        fishvals = [int(a) for a, _ in tallies]
        drops = [(fishvals[i - 1], fishvals[i])
                 for i in range(1, len(fishvals)) if fishvals[i] < fishvals[i - 1]]
        if drops:
            print(f"\n[!] TALLY WENT BACKWARD {drops[:4]} -- duplicate handlers "
                  f"(two script copies with separate state)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
