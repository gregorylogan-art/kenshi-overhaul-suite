# System spine — contracts for every planned system

> **Purpose.** Rule 5 says *contracts first, implementation later* — lock the
> signature early and let v0 internals be garbage, because refactors hurt when
> **interfaces** move, not internals.
>
> This file locks the interfaces for everything on the board, so a future
> session starts from a decided architecture instead of re-deriving one. Nothing
> here is implemented unless it says **SHIPPED**.
>
> Each entry states what it needs from the engine, and whether that capability is
> **verified**, **unknown**, or **banned**. A system whose dependency is banned is
> not "todo" — it is *blocked*, and saying so plainly stops it being picked up
> three times.

---

## Foundational law

Everything below obeys one rule, learned the expensive way (#37):

> **A gameplay loop never writes to a character's inventory.**
> Accumulate outside; transfer on an explicit player action.

`Items` is the single implementation. Any system that produces goods routes
through `Items.bank` / `Items.take` / `Items.collect`, and `Items.verify()`
INV5 trips if one starts writing directly.

---

## SHIPPED

### `Items` — shared grant layer
```lua
Items.bank(ownerKey, itemName, n)    -> total          NO engine calls
Items.take(ownerKey, itemName, n)    -> ok             consume from bag
Items.bagOf(ownerKey)                -> table, count
Items.collect(character, ownerKey)   -> moved, remaining, reason
Items.resolve(character, itemName)   -> GameData|nil   cached, case-sensitive
Items.verify()                       -> violations[]
```
**Engine deps:** `getDataByName` ✅ · `createItem` ✅ · `addItem` ✅ · `hasRoomForItem` ✅

### `Fishing` — the first vertical slice
```lua
Fishing.canFish(character)       -> boolean, reason
Fishing.tryCatch(character)      -> caught, itemId, isGarbage
Fishing.computeOdds(p, s, l)     -> pctNothing, pctJunk
Fishing.collect() / .bag()
```
**Engine deps:** `getWaterLevel` ✅ · `getPosition` ✅ · `xpStat_eventBased` ✅ ·
`registerHandler` ✅ · `createFloatingProgressBar` ✅
**Debt:** owns its own bag; should route through `Items` (needs a live run to confirm parity).

### `Cooking` — economy sink (#18)
```lua
Cooking.canCook(character)   -> boolean, reason
Cooking.cook(character, n)   -> cooked, burnt, reason
Cooking.odds(skill)          -> burnChance        pure
```
**Blocked sub-features:** Cooking XP (stat id unmeasured) · campfire requirement
(actor query unverified).

---

## NEXT — no blockers, buildable now

### `Storage` — town/camp fish supply (#24, #30)
```lua
Storage.deposit(siteKey, itemName, n)  -> total
Storage.withdraw(siteKey, itemName, n) -> ok
Storage.stockOf(siteKey)               -> table, count
```
A `siteKey`-scoped bag. **This is just `Items` with a non-character owner** —
which is the payoff of banking: a dock, a camp, and a character are the same
thing to the ledger. Conservation invariants come free.
**Engine deps:** none beyond `Items`.

### `Vendors` — production → vendors (#28)
```lua
Vendors.priceOf(itemName)                    -> cats
Vendors.sell(character, itemName, n)         -> earned, reason
Vendors.absorb(siteKey, itemName, n)         -> absorbed
```
Must respect the amber-conservation idea ported from StarFall: money paid to a
player is debited from a vendor float, never minted. Otherwise selling fish is
the printer we spent all day preventing.
**Engine deps:** `getOwnerships():addMoney` ✅ (see `90_devcash.lua`).

### `Skills` — dormant-stat framework (#14)
```lua
Skills.grant(character, statKey, amount) -> before, after
Skills.read(character, statKey)          -> value
Skills.register(statKey, statId)         -- measured ids only
```
**Rule:** an id is registered only once **measured live**. Guessing silently
trains the wrong skill. Known: Labouring 3 · Swimming 23 · Perception 24 ·
Precision Shooting 36.

---

## BLOCKED — dependency is banned or unverified

### Fishing rods / spears (#20, #22)
**BLOCKED — engine limit.** `createItem` returns nil at every level for
category-2 weapons. No known workaround from Lua. Do not re-attempt without new
information; this has been tested at levels 0, 1 and 2.

### Real transfer menu (#42)
**BLOCKED — toolchain.** Every GUI construction call returns opaque
`lightuserdata` and there is no `Widget` binding, so a created panel can never be
populated. Needs C++ via KenshiLib → **VS2019+ with the VS2010 (v100) x64
toolset**, which is not installed.
**Available instead:** `FloatingProgressBar` (caption + progress, world-positioned)
and `createScreenLabelD(text, time)`.

### Native job integration (#39)
**UNVERIFIED.** `addJob(t, shift, addDontClear, location)` exists but the task-id
enum is unknown, and an unrecognised id must be assumed to crash until proven
otherwise. Would likely grant the game's own progress bar and work animation for
free — high value, needs a careful probe.

### Animation on gathering (#12, #19)
**BLOCKED.** `AnimationClass` is unbound in Lua. Animation belongs to an FCS job
definition, not a script.

### Boats — crew (#27)
**BLOCKED.** Needs NPC position override + AI suspend; neither verified.

---

## DESIGN DECIDED, NOT STARTED

### Fishing spots as resource nodes (#40)
Greg's observation that harvesting uses a second inventory *for a reason* was
correct and is now proven. The node pattern is the **content** expression of the
same law.
**Decision: both, in order.** Hand fishing anywhere (class fantasy) first;
buildable traps/nets using the node pattern later. Kenshi ships both idioms —
hand-mine a node *and* build mining camps.
**Blocker:** water is continuous; there is no node to attach an output container
to. Needs FCS-authored fishing spots.

### Squad activity panel (#41)
One moveable window, one row per working character, rather than N floating bars.
Scales where per-character bars do not. Same C++ blocker as #42.

---

## Conventions every system follows

| | |
|---|---|
| **Naming** | `kos.*` for cvars/config, never `sf.*` |
| **Globals** | publish with `pcall(function() _G.X = X end)` — the sandbox makes bare writes private |
| **Selftest** | every module exposes `selftest()` runnable with no world |
| **Load order** | `init/` numbered: 05 WSM · 10 Fishing · 15 Items · 24 Cooking |
| **Probes/dev tools** | live in `scripts/`, manual `dofile` only, never `init/` |
| **Deferrals** | become GitHub issues, never silent gaps |
