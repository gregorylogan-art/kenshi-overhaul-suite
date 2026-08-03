# Morning brief — overnight 2026-08-02 → 03

Everything below is **committed, lint-clean, and passing headless tests**.
Nothing here has been seen in a live game, because you were asleep — that
distinction is kept honest throughout.

---

## The big one: we can now run our code without Kenshi

Kenshi ships `lua51.dll` but no interpreter. `tools/luarun.py` drives that DLL
directly through ctypes, so suite modules run in **the same Lua 5.1 the game
uses** with no game open.

```bash
python tools/luarun.py --tests
```

**Why this changes things.** Until now every check was "lint says OK" plus a
play session — and play sessions cost your time and only happen when you're
awake. But look at what actually bit us this week:

| Bug | Needed the game? |
|---|---|
| local used above its declaration → threw on every cast | ❌ no |
| Lua `and` truncating returns → casts hung forever | ❌ no |
| junk band falling through → shipped 5/95 not 5/80/15 | ❌ no |
| odds model never called from the live path | ❌ no |

All four reproduce in a bare interpreter. They cost live sessions anyway.

`tests/test_regressions.lua` now has **30 cases, one per bug we actually
shipped** — not invented ones. It earned its keep on the first run by finding a
floating-point boundary: `0.05 + 0.80 == 0.85000000000000008882`, so the junk
band is one ULP wider than 0.80. Documented rather than "fixed" — the error is
~1e-16 and asserting otherwise would be testing the FPU, not us.

`deploy.sh` now runs **lint → tests → copy**, and refuses on either. I verified
with a deliberate tripwire that a failing test blocks the deploy rather than
reporting after files have already landed.

**Verification tiers, kept straight:** lint proves syntax, headless proves
logic, **only a live session proves engine behaviour.**

---

## Shared item layer — `15_items.lua`

The engine law you identified now has **one implementation** instead of being
re-derived by every system:

```lua
Items.bank(ownerKey, itemName, n)    -- NO engine calls. Safe at any frequency.
Items.take(ownerKey, itemName, n)    -- consume without touching an inventory
Items.collect(character, ownerKey)   -- THE ONLY inventory write in the project
Items.verify()                       -- executable invariant contract
```

**Cherry-picked from StarFall's WorldStateManager (#3637):** its numbered
*executable* invariant contract — rules a function actually checks, so they
can't rot into comments nobody runs. Ours:

1. **Conservation** — banked == collected + held + consumed
2. **Non-negativity** — no negative or fractional quantities
3. **Bag hygiene** — an emptied row is removed, never a zero row
4. **Count agreement** — cached count equals sum of rows
5. **Loop purity** — *inventory writes with no `collect()` call trip this*

**INV5 is your engine law made checkable.** If any future system starts writing
to an inventory from a loop, that invariant catches it instead of a character
freezing in your game.

---

## Cooking — `24_cooking.lua` (#18)

The economy sink, and **the first system built on the engine law from the start**
rather than retrofitted:

```
Raw fish --cook--> Cooked fish     (worth more, edible)
                \-> Burnt fish     (worth almost nothing)
```

Burning **is** the sink. Skill lowers it — 40% at zero, 5% at max — but it never
reaches zero, because a lossless conversion turns fishing back into a printer.

Consumes raw fish from the catch bag and banks product back. **Zero inventory
calls anywhere**, which means production chains can run entirely outside the
inventory and only the finished good ever crosses over.

**Deferred honestly, not silently:**
- **Cooking XP is OFF.** Our stat ids are measured (Labouring 3, Swimming 23,
  Perception 24, Precision Shooting 36); Cooking's is unknown. Guessing an id
  silently trains the wrong skill.
- **No campfire requirement yet** — binding to a cooking station needs an actor
  query we haven't verified.

---

## Closed / updated

- **#35 closed** — verified `init/` holds only real systems; every probe and dev
  tool is manual-`dofile` only, and `deploy.sh` enforces the split by
  construction.
- **#37 updated** — shared grant helper shipped (its "Wanted" item). Left
  **open**: this is avoidance, not root cause. What Kenshi does internally when a
  script queries a saturated inventory is still unknown.

---

## What I deliberately did NOT do

**I did not migrate fishing onto `Items`.** It has its own working bag, so there
is now duplicated logic — real debt, and I'd normally remove it. But fishing is
the one thing you've verified live, and a behaviour-preserving refactor still
needs a live run to *confirm* it preserved behaviour. Doing that while you slept
would mean handing you a possibly-broken fishing loop with no way to have known.

It's a ~20-minute job with you awake to test. That's the first thing I'd pick up.

---

## Suggested order when you're back

1. **Restart and confirm nothing regressed** — the fishing loop is untouched, but
   two new modules now load at startup.
2. **`Cooking.status()`** then **`Cooking.cook(char, 5)`** — needs raw fish
   banked first. Will tell us whether your FCS item names resolve.
3. **Migrate fishing onto `Items`** — kills the duplication, with you there to
   verify.
4. Then #40 (fishing spots) or the VS2010 toolset for #42's real menu.

---

## Numbers

- 3 module selftests: **31 checks, 0 failed**
- Regression suite: **30 checks, 0 failed**
- Lint: **0 findings across 8 files**
- Commits pushed: 4
- **Live-verified: nothing.** All of the above is headless.
