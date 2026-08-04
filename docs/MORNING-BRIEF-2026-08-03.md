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

## Second session (while you were out) — migration done

**Fishing now runs on the shared `Items` ledger.** Done in the safe order:

1. **Characterization tests written first** (17 checks), pinning the behaviour
   you'd already verified live — per-item counts, the drain loop, and the case
   that matters most: *a refusal keeps the remainder banked rather than
   destroying the catch.*
2. Migration.
3. Same tests re-run against the migrated path.

The tests **call** the real entry points rather than replicating their bodies —
a test that reimplements the code it checks passes happily while the shipped
path rots underneath it, which is exactly how the inert skill model survived a
whole session here. One assertion exists purely to prove the migration happened:
banking must land in `Items.counts`, not a private table.

`Items` renumbered 15 → 08 so it loads before its consumers, but it's resolved
**lazily** per call, so ordering is a convenience rather than a dependency. If
`Items` ever fails to load, fishing degrades to the old private bag instead of
erroring.

### A real bug caught before it reached you

Fishing banks **"Small Fish"**. Cooking's raw list is headed by **"Raw Fish"**
(your FCS item). *Both resolve*, so cooking would have picked "Raw Fish", found
none banked, and reported **"nothing to cook" over a bagful of fish**.

In a live session that reads as *cooking is broken*, not as two systems
disagreeing about a name. Fixed — what's in the bag wins — and pinned with a
HANDOFF test that banks exactly what fishing produces and consumes exactly what
cooking would.

**This is the harness paying for itself on day one.**

---

## Suggested order when you're back

1. **Restart and fish a normal run.** This is the one that matters — fishing now
   banks through a different code path than the one you verified. Same
   behaviour by 17 headless checks, but only a live run proves the mint.
2. **`Cooking.status()`** with fish banked, then **`Cooking.cook(char, 5)`** —
   tells us whether your FCS item names resolve against a real character.
3. Then #40 (fishing spots) or the VS2010 toolset for #42's real menu.

---

## Numbers

- 3 module selftests: **31 checks, 0 failed**
- 3 test suites (regressions / fishing bag / handoff): **53 checks, 0 failed**
- Lint: **0 findings across 8 files**
- Commits pushed: 7
- **Live-verified: nothing.** All of the above is headless.

## Rollback, if anything is wrong

Every change is a separate commit, so a single revert undoes exactly one thing:

```bash
git revert 6ff89bf   # cooking name-mismatch fix
git revert b511f64   # fishing -> Items migration
```
