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

  L7  inventory write outside 08_items.lua
      The engine law (#37): a gameplay loop must never write to a character's
      inventory directly -- accumulate outside, transfer through Items.collect.
      08_items.lua's own runtime invariant (INV5) can only see calls that were
      ROUTED through it; a future system calling :addItem(/:createItem( directly
      is invisible to a counter that never runs. This is the same violation as
      a static check instead of a runtime one -- it catches the bypass a
      counter structurally cannot.

      Suppressible with an inline marker, same line or the line directly
      above: `-- L7-ALLOW: <reason>`. Every exception must state why in the
      diff, so the rule stays meaningful rather than quietly acquiring a
      filename allowlist nobody re-reads. Two genuine exceptions exist today:
      a Rule-4 fallback for when Items.lua itself fails to load, and a manual
      probe that creates items to inspect their fields without ever granting
      them (createItem with no matching addItem is not a grid write).

Usage:
    python tools/lua_check.py                 # check all shipped scripts
    python tools/lua_check.py path/to/x.lua
"""
from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / "mods" / "suite_scripts" / "scripts"

BANNED_INTERNALS = ("process", "mainThreadUpdate", "flush", "drain", "dispatch")
DESTRUCTIVE = ("removeItemAutoDestroy", "removeItemDontDestroy", "clearAll",
               "dropItem", "takeItem_EntireStack", "_DESTRUCTOR")
CONTAINER_HINTS = (".sections", "platoonKillList", "getActivePlatoons",
                   "activeEffects", "whoSeesMeSneaking", "disguiseGUIFeedbacks")
# The one file allowed to write to an inventory. Everything else must route
# through Items.collect() -- this is the engine law (#37) as a filename check.
ITEMS_MODULE = "08_items.lua"


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

        # --- L7: inventory write outside the Items module --------------------
        if path.name != ITEMS_MODULE:
            if re.search(r":\s*addItem\s*\(", l) or re.search(r":\s*createItem\s*\(", l):
                # Look back up to 3 lines: the common idiom is
                #     -- L7-ALLOW: reason
                #     local ok, x = pcall(function()
                #         return obj:createItem(...) end)
                # which puts the marker two lines above the actual call.
                window = lines[max(0, i - 4):i - 1]
                allowed = "L7-ALLOW:" in l or any("L7-ALLOW:" in wl for wl in window)
                if not allowed:
                    out.append((i, "L7", "inventory write outside 08_items.lua -- "
                                         "route through Items.bank/.collect instead (#37 engine law)"))

    # --- L5: handlers without a reload guard --------------------------------
    if "registerHandler(" in src:
        if "_generation" not in src and "unregisterHandler" not in src:
            n = next((i for i, l in enumerate(lines, 1) if "registerHandler(" in l), 1)
            out.append((n, "L5", "registers a handler with NO reload/generation guard -- "
                                 "dofile will stack duplicate script copies"))
    return out


def _selftest() -> int:
    """python tools/lua_check.py --selftest -- exercise the rules against
    synthetic snippets, so a change to the regex or the lookback window is
    caught here rather than by re-reading real findings by eye. L7 earned this
    the hard way: its first version's 1-line lookback silently failed to
    recognise its own marker on the common `pcall(function() ... end)` idiom,
    and the only reason that surfaced was a human noticing the count of
    findings did not match expectation.
    """
    passed, failed = 0, 0

    def case(name: str, filename: str, src: str, want_rule: str | None):
        nonlocal passed, failed
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / filename
            p.write_text(src, encoding="utf-8")
            found = check(p)
            rules = {r for _, r, _ in found}
            ok = (want_rule in rules) if want_rule else (len(found) == 0)
            if ok:
                passed += 1
            else:
                failed += 1
                print(f"  FAIL: {name} -- wanted {want_rule!r}, got {sorted(rules)}")

    # L1: use before file-level local declaration
    case("L1 fires on use-before-declare", "x.lua",
         "print(theValueHere)\nlocal theValueHere = 1\n", "L1")
    case("L1 silent on ordinary code", "x.lua",
         "local theValueHere = 1\nprint(theValueHere)\n", None)

    # L2: banned engine internals
    case("L2 fires on :process(", "x.lua", "factory:process()\n", "L2")
    # NOTE: an ordinary call cannot use :createItem(/:addItem( here as the
    # "nothing fires" example -- both unconditionally trip L7 (inventory
    # write outside 08_items.lua) on any file that is not 08_items.lua, which
    # would fail this case for the wrong reason. Exactly the cross-rule
    # contamination mistake L7's own lookback bug already cost a debugging
    # cycle for -- caught here before it shipped as a second copy of it.
    case("L2 silent on an ordinary method call", "x.lua", "factory:getHandle()\n", None)

    # L3: destructive inventory calls -- previously untested, same class of
    # gap L7's own history warns about: a rule with no selftest coverage can
    # silently break and nothing notices until a real finding goes missing.
    case("L3 fires on removeItemAutoDestroy", "x.lua",
         "inv:removeItemAutoDestroy(item)\n", "L3")
    case("L3 fires on dropItem", "x.lua", "inv:dropItem(item)\n", "L3")
    case("L3 silent on an unrelated call", "x.lua", "inv:getNumItems()\n", None)

    # L4: fabricated out-of-domain arguments -- also previously untested.
    case("L4 fires on a negative createItem level", "x.lua",
         "factory:createItem(gd, hand, nil, nil, -1, nil)\n", "L4")
    # filename is 08_items.lua here so this line does not ALSO trip L7 --
    # isolates the L4-specific claim (level 0 is fine) from the unrelated
    # inventory-write rule, same reasoning as the L2 case above.
    case("L4 silent on a real level (0)", "08_items.lua",
         "factory:createItem(gd, hand, nil, nil, 0, nil)\n", None)
    case("L4 fires on a wide fabricated enum sweep", "x.lua",
         "for cat = 0, 40 do\n  container:getDataByName(name, cat)\nend\n", "L4")
    case("L4 silent on a loop over the measured categories only", "x.lua",
         "for _, cat in ipairs({2,3,4}) do\n  container:getDataByName(name, cat)\nend\n", None)
    case("L4 silent on a small 0-based loop (below the 40-ish threshold)", "x.lua",
         "for cat = 0, 3 do\n  container:getDataByName(name, cat)\nend\n", None)

    # L5: registerHandler with no reload/generation guard -- also previously
    # untested.
    case("L5 fires on registerHandler with no guard at all", "x.lua",
         'registerHandler("onCharsUpdate", function() end)\n', "L5")
    case("L5 silent when a generation guard is present", "x.lua",
         'local MY_GEN = 1\n_generation = MY_GEN\nregisterHandler("onCharsUpdate", function() end)\n',
         None)
    case("L5 silent when unregisterHandler is present", "x.lua",
         'registerHandler("onCharsUpdate", function() end)\nunregisterHandler(1)\n', None)

    # L6: container-typed member access
    case("L6 fires on a known container hint", "x.lua",
         "print(faction.platoonKillList)\n", "L6")

    # L7: the one that shipped a real bug (narrow lookback window)
    case("L7 fires on a bare addItem outside items.lua", "x.lua",
         "inv:addItem(item, 1, false, true)\n", "L7")
    case("L7 fires on a bare createItem outside items.lua", "x.lua",
         "factory:createItem(gd, hand, nil, nil, 0, nil)\n", "L7")
    case("L7 silent inside 08_items.lua itself", "08_items.lua",
         "inv:addItem(item, 1, false, true)\n", None)
    case("L7 silent with a same-line marker", "x.lua",
         "inv:addItem(item, 1, false, true)  -- L7-ALLOW: test\n", None)
    case("L7 silent with marker 1 line above", "x.lua",
         "-- L7-ALLOW: test\ninv:addItem(item, 1, false, true)\n", None)
    case("L7 silent with marker through a pcall(function() wrapper (the real bug)",
         "x.lua",
         "-- L7-ALLOW: test\n"
         "local ok, item = pcall(function()\n"
         "    return factory:createItem(gd, hand, nil, nil, 0, nil) end)\n",
         None)
    case("L7 still fires past the lookback window", "x.lua",
         "-- L7-ALLOW: test\n\n\n\ninv:addItem(item, 1, false, true)\n", "L7")

    print(f"--- lua_check.py SELFTEST: {passed} passed, {failed} failed ---")
    return 1 if failed else 0


def rel(p: Path) -> str:
    """Display path -- falls back to the raw path for files outside the repo."""
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return _selftest()

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
