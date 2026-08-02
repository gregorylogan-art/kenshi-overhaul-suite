#!/usr/bin/env python3
"""lua_check.py -- static checks for the bug classes THIS project actually hit.

Not a general Lua linter. Every rule here exists because the bug cost us a real
debugging cycle in the game, where a mistake means a restart at best and a
corrupted save at worst.

RULES
  L1  use-before-declare of a file-local
      Cost: FISH_PREFERENCE was declared below tryCatch, so it was nil inside
      it and EVERY cast threw "bad argument #1 to 'ipairs'". Symptom looked
      like "casting does nothing" -- nowhere near the actual fault.

  L2  banned engine internals
      factory:process() HARD CRASHED the game. process/mainThreadUpdate/update/
      run are engine internals; gen_probes.py already bans them, but a
      hand-written script bypassed that rule.

  L3  destructive inventory calls
      removeItemAutoDestroy / clearAll / dropItem can destroy player items.
      Allowed, but must be deliberate -- flagged so they are never accidental.

  L4  fabricated out-of-domain arguments
      Passing -1 as a C++ level/quality parameter is the same class as passing
      garbage into a pointer.

  L5  registerHandler without a generation/reload guard
      dofile re-registering handlers produced TWO live script copies with
      divergent state (two different catch tallies at once).

  L6  container-typed member access
      Reading lektor<T*> / .sections / std:: members hard-crashes the process,
      and pcall does NOT catch a native access violation.

Usage:
    python tools/lua_check.py                 # check all shipped scripts
    python tools/lua_check.py path/to/x.lua
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / "mods" / "suite_scripts" / "scripts"

BANNED_INTERNALS = ("process", "mainThreadUpdate", "flush", "drain", "dispatch")
DESTRUCTIVE = ("removeItemAutoDestroy", "removeItemDontDestroy", "clearAll",
               "dropItem", "takeItem_EntireStack", "_DESTRUCTOR")
CONTAINER_HINTS = (".sections", "platoonKillList", "getActivePlatoons",
                   "activeEffects", "whoSeesMeSneaking", "disguiseGUIFeedbacks")


def check(path: Path):
    src = path.read_text(encoding="utf-8", errors="replace")
    lines = src.splitlines()
    out = []

    # --- L1: FILE-LEVEL local used above its declaration --------------------
    # Only file-level (column-0) locals matter: a local inside a function is
    # scoped to it, and a same-named function PARAMETER elsewhere is unrelated.
    # An earlier version ignored that and produced only false positives -- and a
    # linter that cries wolf is worse than none when deploy.sh gates on it.
    params = set()
    for l in lines:
        m = re.search(r"function[^(]*\(([^)]*)\)", l)
        if m:
            for p in m.group(1).split(","):
                p = p.strip()
                if p:
                    params.add(p)

    decls = {}
    for i, l in enumerate(lines, 1):
        m = re.match(r"local\s+([A-Za-z_]\w*)\s*(=|$)", l)   # column 0 only
        if m:
            decls.setdefault(m.group(1), i)

    for name, decl_line in decls.items():
        if len(name) < 4 or name in params:
            continue
        for i, l in enumerate(lines[:decl_line - 1], 1):
            s = l.strip()
            if s.startswith("--") or re.search(r"\blocal\s+function\b", s):
                continue
            # a bare mention inside a comment-free line that is not itself a decl
            if re.search(rf"\b{re.escape(name)}\b", s) and not s.startswith("local "):
                out.append((i, "L1", f"'{name}' used at line {i} but declared at {decl_line} "
                                     f"(Lua locals are invisible above their declaration)"))
                break

    for i, l in enumerate(lines, 1):
        stripped = l.strip()
        if stripped.startswith("--"):
            continue

        # --- L2: engine internals ------------------------------------------
        for bad in BANNED_INTERNALS:
            if re.search(rf":\s*{bad}\s*\(", l):
                out.append((i, "L2", f"calls engine internal ':{bad}()' -- process() hard-crashed the game"))

        # --- L3: destructive inventory --------------------------------------
        for bad in DESTRUCTIVE:
            if bad in l:
                out.append((i, "L3", f"destructive call '{bad}' -- must be deliberate, can destroy player items"))

        # --- L4: fabricated out-of-domain args -------------------------------
        if re.search(r"createItem\s*\([^)]*,\s*-\d", l):
            out.append((i, "L4", "negative value passed to a C++ level/quality parameter"))
        if re.search(r"for\s+\w+\s*=\s*0\s*,\s*([4-9]\d|\d{3,})\b", l) and "getDataByName" in src:
            out.append((i, "L4", "wide fabricated enum sweep -- use the MEASURED categories (2,3,4)"))

        # --- L6: container access -------------------------------------------
        for hint in CONTAINER_HINTS:
            if hint in l:
                out.append((i, "L6", f"container-typed access '{hint}' -- HARD CRASH class, pcall cannot catch it"))

    # --- L5: handlers without a reload guard --------------------------------
    if "registerHandler(" in src:
        if "_generation" not in src and "unregisterHandler" not in src:
            n = next((i for i, l in enumerate(lines, 1) if "registerHandler(" in l), 1)
            out.append((n, "L5", "registers a handler with NO reload/generation guard -- "
                                 "dofile will stack duplicate script copies"))
    return out


def rel(p: Path) -> str:
    """Display path -- falls back to the raw path for files outside the repo."""
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def main() -> int:
    targets = [Path(a) for a in sys.argv[1:]] or sorted(DEFAULT.rglob("*.lua"))
    targets = [t for t in targets if "_disabled" not in str(t) and "probe_manifest" not in t.name]

    total = 0
    for t in targets:
        findings = check(t)
        if not findings:
            print(f"  OK    {rel(t)}")
            continue
        print(f"\n=== {rel(t)} ===")
        for line, rule, msg in sorted(findings):
            print(f"  {rule}  line {line}: {msg}")
            total += 1
    print(f"\n{total} finding(s) across {len(targets)} file(s)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
