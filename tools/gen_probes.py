#!/usr/bin/env python3
"""gen_probes.py -- turn KenshiLua's BindingsReference.md into a SAFE Lua probe manifest.

WHY: BindingsReference.md is auto-generated from C++ headers. It documents what
*should* exist; none of it has been executed. KenshiLua's own README admits the
AI-assisted binding generation produced "duplicated functionality, broken
bindings, and orphaned code." So the docs are a hypothesis, not ground truth.

This emits a manifest the in-game probe runner uses to produce a VERIFIED
capability matrix (works / broken / absent) that every suite system is then
built against -- instead of trusting the docs.

SAFETY IS THE WHOLE DESIGN. Probing runs against a LIVE game with the player's
characters. Calling the wrong method crashes Kenshi or corrupts a save. Rules:

  1. ZERO-ARG METHODS ONLY. We cannot fabricate valid arguments for a
     `Character*` or an enum, and passing garbage into a C++ pointer arg is a
     crash. Anything taking arguments is recorded as NEEDS_ARGS and never called.
  2. READ-VERB ALLOWLIST. Only get/is/has/can/calculate/count/... prefixes are
     called. A method is guilty until proven innocent -- an unrecognized verb is
     NOT probed.
  3. DESTRUCTIVE BLOCKLIST wins over everything, even if it looks like a getter
     (`getDestroyed` style names, `_DESTRUCTOR`, init, kill, remove, save/load).
  4. FIELDS ARE READ, NEVER WRITTEN. Reading is cheap and safe; writing to a
     live RW field could desync the game or the save.
  5. CONTAINER-TYPED FIELDS ARE EXCLUDED. Learned the hard way: reading
     `Faction.platoonKillList` (type `lektor<Platoon*>`) hard-crashed Kenshi.
     Reading a container of pointers makes C++ construct/iterate it, which
     touches memory Lua cannot validate -- and pcall does NOT catch a native
     access violation. Scalars and single objects are fine; containers are not.

Usage:
    python tools/gen_probes.py            # writes mods/suite_scripts/scripts/probe_manifest.lua
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "third_party" / "KenshiLua" / "docs" / "BindingsReference.md"
OUT = ROOT / "mods" / "suite_scripts" / "scripts" / "probe_manifest.lua"

# --- Rule 3: destructive/stateful names. Checked FIRST, substring, case-insensitive.
# Anything matching is never called no matter how safe its prefix looks.
BLOCK = (
    "destructor", "destroy", "init", "kill", "die", "dead", "remove", "delete",
    "clear", "reset", "release", "free", "close", "shutdown", "quit", "exit",
    "save", "load", "write", "commit", "apply", "amputate", "damage", "hit",
    "attack", "equip", "drop", "give", "take", "buy", "sell", "steal", "pay",
    "spawn", "create", "make", "build", "construct", "add", "insert", "push",
    "set", "update", "tick", "step", "advance", "start", "stop", "pause",
    "enable", "disable", "toggle", "activate", "deactivate", "select",
    "notify", "send", "call", "execute", "run", "do", "force", "trigger",
    "recruit", "enslave", "capture", "teleport", "move", "walk", "path",
)

# --- Rule 5: container/collection field types. Reading one iterates C++ memory
# and can hard-crash the process (confirmed: Faction.platoonKillList).
CONTAINER_TY = (
    "lektor<", "std::", "vector<", "deque<", "list<", "map<", "set<",
    "unordered", "array<", "queue<", "pair<", "::type", "[]",
)


def unsafe_field_type(ty: str) -> bool:
    low = (ty or "").lower()
    return any(c.lower() in low for c in CONTAINER_TY)


# --- Rule 2: read-verb allowlist. Method must START with one of these.
READ_PREFIX = (
    "get", "is", "has", "can", "are", "was", "should", "calculate", "compute",
    "count", "num", "find", "query", "check", "test", "peek", "read", "to",
)


def parse(md: str):
    """-> {class: {"fields":[(name,type,rw)], "methods":[(name,args,ret)]}}"""
    classes: dict[str, dict] = {}
    cls = None
    section = None
    for line in md.splitlines():
        m = re.match(r"^## +(\w[\w:]*)\s*$", line)
        if m:
            cls = m.group(1)
            classes[cls] = {"fields": [], "methods": []}
            section = None
            continue
        if line.startswith("### Fields"):
            section = "fields"; continue
        if line.startswith("### Methods"):
            section = "methods"; continue
        if not cls or not section or not line.startswith("|"):
            continue
        cells = [c.strip().strip("`") for c in line.strip("|").split("|")]
        if len(cells) < 4 or cells[0] in ("Lua Name", "---", ""):
            continue
        if cells[0].startswith("---"):
            continue
        if section == "fields":
            classes[cls]["fields"].append((cells[0], cells[2], cells[3]))
        else:
            classes[cls]["methods"].append((cells[0], cells[2], cells[3]))
    return classes


def classify(name: str, args: str, ret: str = "") -> str:
    """SAFE_CALL | NEEDS_ARGS | UNSAFE -- guilty until proven innocent."""
    low = name.lower().lstrip("_")
    # Rule 5 applies to RETURN types too: Faction:getActivePlatoons returns a
    # container of pointers and hard-crashed the game exactly like the field
    # form did. Constructing the container is what kills it, not how it is
    # reached.
    if unsafe_field_type(ret):
        return "UNSAFE"
    # Rule 3 first: blocklist beats everything.
    for bad in BLOCK:
        if bad in low:
            return "UNSAFE"
    # Rule 1: no arguments we can't fabricate.
    if args.strip():
        return "NEEDS_ARGS"
    # Rule 2: must be a recognized read verb.
    for good in READ_PREFIX:
        if low.startswith(good):
            return "SAFE_CALL"
    return "UNSAFE"


def lua_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main() -> int:
    if not DOCS.is_file():
        print(f"ERROR: bindings doc not found: {DOCS}", file=sys.stderr)
        return 2
    classes = parse(DOCS.read_text(encoding="utf-8", errors="replace"))

    n_safe = n_args = n_unsafe = n_fields = n_field_blocked = 0
    out = [
        "-- AUTO-GENERATED by tools/gen_probes.py -- do not edit by hand.",
        "-- Safe-to-call zero-arg readers + readable fields, per class.",
        "-- UNSAFE and NEEDS_ARGS entries are deliberately omitted: they are never called.",
        "return {",
    ]
    for cls in sorted(classes):
        d = classes[cls]
        safe = [m for m in d["methods"] if classify(m[0], m[1], m[2]) == "SAFE_CALL"]
        n_args += sum(1 for m in d["methods"] if classify(m[0], m[1], m[2]) == "NEEDS_ARGS")
        n_unsafe += sum(1 for m in d["methods"] if classify(m[0], m[1], m[2]) == "UNSAFE")
        n_safe += len(safe)
        fields = [f for f in d["fields"] if not unsafe_field_type(f[1])]
        n_field_blocked += len(d["fields"]) - len(fields)
        n_fields += len(fields)
        if not safe and not fields:
            continue
        out.append(f'  ["{cls}"] = {{')
        if safe:
            out.append("    methods = {")
            for nm, _a, ret in safe:
                out.append(f'      {{ name = "{lua_escape(nm)}", ret = "{lua_escape(ret)}" }},')
            out.append("    },")
        if fields:
            out.append("    fields = {")
            for nm, ty, rw in fields:
                out.append(f'      {{ name = "{lua_escape(nm)}", ty = "{lua_escape(ty)}", rw = "{lua_escape(rw)}" }},')
            out.append("    },")
        out.append("  },")
    out.append("}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")

    total_m = n_safe + n_args + n_unsafe
    print(f"classes parsed      : {len(classes)}")
    print(f"methods total       : {total_m}")
    print(f"  SAFE_CALL (probed): {n_safe}")
    print(f"  NEEDS_ARGS (skip) : {n_args}")
    print(f"  UNSAFE (blocked)  : {n_unsafe}")
    print(f"fields (read-only)  : {n_fields}")
    print(f"  container blocked : {n_field_blocked}  (crash class: lektor<T*> etc)")
    print(f"-> {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
