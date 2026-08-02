# Morning brief — 2026-08-02

Overnight work while you slept. **Read this first; it is the whole state of the project.**

## Where fishing actually stands

| Piece | State |
|---|---|
| Wade band (waterLevel 1–2) | ✅ verified in game |
| Standstill + 5s cast | ✅ verified |
| Outcome table 5 / 80 / 15 | ✅ verified |
| Real item into inventory | ✅ **your FCS `Small Fish` is being caught** |
| 4 FCS items authored | ✅ all four resolve |
| Junk granting | ⛔ **disabled** — suspected save damage |
| XP granting | ⚠️ re-enabled for isolation test A, **produced no output** |
| Cooking / burn | ⛔ disabled (calls a destructive API) |

**Healthy baseline confirmed:** with everything off and no console commands, you got 1 cast = 1 fish, working inventory, responsive character.

## The one open safety question (#21)

Your character broke **twice**: no orders accepted, **inventory would not open**, stats screen flashed and closed — while the game kept running.

That reads as the inventory UI failing to *render* an item. We mint everything with `createItem(gd, hand, nil, nil, 0, nil)`. Food (cat 4) displays fine all session. Weapons (cat 2) return nil at every level. **Clothing/misc (cat 3) create successfully but may be malformed** — enough for `addItem`, not enough to draw.

**Isolation plan — one flag at a time:**
1. ✅ Baseline (both off) — healthy
2. ⏳ **Test A: XP only** — deployed, but the skill script printed nothing at all
3. ⏸ Test B: junk only ← the real suspect

⚠️ A save already containing malformed items may stay broken no matter what we change. Prefer a fresh or expendable character.

## First thing to run tomorrow

Restart Kenshi (**no console commands** — `init/` auto-loads), then in the console:

```lua
WSM.selftest()
```

Needs no character and no world. Then check the log for:

```
=== 19_fishing_skill.lua BEGIN ===
```

I added BEGIN/END heartbeats because that file reported as "loaded" while producing **zero output and no error** — so we could not tell whether it ran. Now:
- **No BEGIN line** → the chunk never executed (compile/load failure)
- **BEGIN but no END** → it died in between, and the last line printed marks the spot

## Built overnight

**WSM v0.1** — `scripts/init/05_wsm.lua`. Pure Lua control plane, no engine calls, testable with the game paused.
- Mutate contract: apply → log → trim
- Re-entrant writes **refused loudly** rather than corrupting quietly
- Snapshot/restore, subscriptions, cvars all default 0
- `WSM.selftest()` verifies the whole contract in-process

**Both StarFall tick bugs designed out** — this file has exactly the catch-up that caused them:
1. **Monotonic day counter** — cannot wrap-freeze a system (froze 23 StarFall subsystems)
2. **`catchUp` advances only for completed days** — failed days retry rather than vanish (lost work in 22 more)

## GitHub is now the full picture

**33 open issues, 9 milestones, all 8 packages covered.** Closed 4 stale stubs superseded by better ones.

Highlights worth reading: **#21** (safety), **#22** (weapons cannot be created — blocks rods/spears), **#23** (case-sensitive lookups), **#34** (Projector).

## Engine limits discovered (all recorded)

| Limit | Consequence |
|---|---|
| `AnimationClass` unbound | animation belongs to FCS jobs, not Lua |
| Weapons unmintable via `createItem` | rods/spears blocked (#22) |
| No FCS failure-chance field | burn chance must live in Lua |
| No FCS "edible raw" toggle | must-cook cannot be enforced by the item |
| `getDataByName` case-sensitive, silent | copy names verbatim from FCS |
| Container members hard-crash | never read `lektor<T*>` etc |
| Engine internals hard-crash | never call `process()`/`update()` |
| No `io` library | the log is the only output channel |

## Honest assessment

Fishing's **core loop is real and working**. What is not settled is whether our item-minting route is safe for anything except food — and that is exactly the kind of thing that damages saves, so it stays disabled until isolated.

The fastest path tomorrow: run **Test B** (junk only) on a character you do not care about. If the inventory breaks, we have the culprit and stop granting cat-3 items until `createItem` is understood properly.
