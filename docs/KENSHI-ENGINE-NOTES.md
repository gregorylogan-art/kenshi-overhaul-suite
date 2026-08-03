# Kenshi engine notes — verified facts

> **Purpose.** Kenshi's Lua surface is barely documented and the bindings
> reference is wrong often enough that it cannot be trusted on its own
> (~29 confirmed cases). Everything here was **verified live** or **read from
> the game's own data files**. Guesses are labelled as guesses.
>
> Greg, 2026-08-02: *"this will be a long battle with kenshi as we progress more
> info the better."* Add to this file whenever something is proven. A fact that
> cost a debugging session and then got forgotten costs it twice.

---

## 1. Hard rules (learned by crashing)

| Rule | Why |
|---|---|
| **`pcall` does NOT catch native access violations** | A C++ crash takes the process down regardless. Wrapping is not safety. |
| **Never touch container types** (`lektor<T*>`, std:: containers) | Hard-crashed the game twice: `Faction.platoonKillList`, `Faction:getActivePlatoons`. |
| **Never call engine internals** (`process()`, `mainThreadUpdate()`, `update()` on engine objects) | `factory:process()` hard-crashed the game. |
| **Docs argument columns are unreliable** | Signatures were reconstructed from *argument errors*, not docs. |
| **`getDataByName(name, category)` is CASE-SENSITIVE and fails silently** | Returns nil, no error. |
| **Verify writes by reading back** | A call returning "success" proved nothing: `copyItem`+`addItem` reported OK for an item that was never in the inventory. |

### Sandboxing
KenshiLua gives every script its own environment (`ScriptLoader.cpp`,
`createSandboxEnv`):
```
env = {}; setmetatable(env, { __index = _G }); lua_setfenv(chunk, env)
```
**Reads fall through to `_G`; writes stay private.** There is no `__newindex`.

- A bare `Foo = {}` is invisible to every other script *and to the console*.
- Symptom: `[string "<editor>"]:1: attempt to index global 'Fishing' (a nil value)`
- This silently made a cross-file `Fishing.grantXp` read `nil` for a whole session.
- **Fix:** publish explicitly — `pcall(function() _G.Foo = Foo end)`

### Script loading
- Auto-load **only** from `mods/<ActiveMod>/scripts/init/*.lua`
- `scripts/` is manual `dofile` only — correct place for dev/cheat tools
- **`print()` during ScriptLoader init is SWALLOWED** (logger not capturing yet).
  Queue log lines at load, flush on first tick.
- **Restart OR `dofile`, never both** — you get two script copies with divergent
  state (observed: `fish=17` and `fish=6` from the same run).

---

## 2. Items

### The verified mint→grant chain
```lua
local container = character:getFaction():getData().sourceContainer
local gd        = container:getDataByName("Dried Fish", 4)   -- CASE-SENSITIVE
local item      = getRootObjectFactory():createItem(gd, inv:getHandle(), nil, nil, 0, nil)
local ok        = inv:addItem(item, 1, false, true)
```

- **Categories:** `2` = weapons, `3` = clothing/armour, `4` = food/materials
- **`createItem` level arg:** `0` works for food/materials; **weapons return nil at
  every level** — weapon creation is unsolved (blocks fishing rods/spears)
- **`addItem(item, quantity, dropOnFail, destroyOnFail)`** — use
  `dropOnFail=false`. A fishing character stands in water; asking the engine to
  place a world object there is its own hazard.

### `hasRoomForItem` is per-item, NOT a fullness test
Measured live:
```
grant 8  : Empty Rum Bottle | refused, hasRoomForItem=false
grant 9  : Small Fish       | GRANTED   <- 1x1 fits a gap the bottle could not
grant 10 : Damaged Book     | GRANTED
```
A pack can report "no room" for one item and still accept several more.

**Probe item choice matters.** A clothing item (category 3) is useless as a
fullness probe — Kenshi can place clothing in **equipment slots** rather than the
grid, so "room for a Straw Hat" stays true long after the grid is solid. This
caused 18 consecutive refused grants while the guard reported space. Use a
**category-4, multi-cell** item (e.g. `Book`).

---

## 3. GUI

### Getting the GUI
```lua
local gui = getForgottenGUI()   -- VERIFIED: returns userdata
```
**This accessor appears nowhere in the bindings docs.** It was found by probing.
`getPlayerInterface()` also returns userdata (unexplored).

### Floating progress bar
```lua
local bar = gui:createFloatingProgressBar()
bar:setCaption("...")
bar:setPosition({ x = , y = , z = })   -- WORLD coords
bar:setProgress(n)
bar:update()
```

**Measured field support** (introspected live) — the Lua binding does **NOT**
inherit `ScreenLabel`'s surface despite sharing `kenshi/gui/ScreenLabel.h`:

| Field | Present? | Consequence |
|---|---|---|
| `setPosition` | ✅ function | position manually each tick |
| `setCaption` | ✅ function | |
| `trackingHandle` | ❌ nil | **cannot auto-follow a character** |
| `trackingOffset` | ❌ nil | |
| `destroy` | ❌ nil (errors) | **no teardown → one bar per character, reused forever** |
| `destroyed` | ❌ nil | |

- **The FIELD and the METHOD take DIFFERENT SCALES.** This one cost a test cycle:
  ```lua
  bar.progress = math.floor(frac * 1000)   -- FIELD:  0..1000 (widget RangePosition)
  bar:setProgress(frac)                    -- METHOD: 0..1 fraction
  ```
  `Range=1000` comes from `data/gui/layout/Kenshi_ProgressBarPanel.layout` and
  matches the binding's `progress | integer`. But feeding a 1000-scale value to
  `setProgress()` **clamps to full** — the bar then snaps between 0 and 100%
  instead of filling, which reads as "it refreshes rather than loads".
- An unpositioned bar sits at **world origin** — invisible, looks like failure.
- **Y is UP.** Confirmed: character `y=88.9` vs `terrainH=88.88` same session.
  `+2` units is ankle height; head height is roughly `+12`.

### Useful layouts (game's own, readable on disk)
| File | What |
|---|---|
| `Kenshi_ProgressBarPanel.layout` | floating panel: progress bar + caption |
| `Kenshi_GenericBuildingWindow.layout` | resource-node window (inventory + progress) |

### Window control (untested — candidate freeze recovery)
`ForgottenGUI` exposes `closeAllInventories`, `closeAllCharacterStatsWindows`,
`closeAllWindows`, `clearGUI`, `isStatsWindowOpen`, `getNumOpenInventoryWindows`.
Wrapped as `Fishing.unstick()`.

---

## 4. Characters

| Call | Status |
|---|---|
| `getSelectedCharacter()` | ✅ returns one Character |
| `character:getName()` | ✅ |
| `character:getPosition()` | ✅ Vector3 (Y up) |
| `character:getWaterLevel()` | ✅ integer |
| `character:getStats()` / `:getInventory()` | ✅ |
| `character:getHandle()` | ✅ userdata (`RootObjectBase:getHandle`) |
| `character:getPos()` | ❌ does not exist |
| `character:getHealth()` | ❌ does not exist |
| `CharStats:calculateMaxSwimSpeed()` | ❌ does not exist |

### Water
- `waterLevel`: `0` = land, `1–2` = wading, `3` = deep/swimming
- **`CharStats.swimming` is a LAGGING ACCUMULATOR, not a boolean and not depth.**
  It read **12.91 on dry land**. Gating on it blocks fishing everywhere. Use
  `waterLevel`.
- Swimming locks the animation state — no custom animation can play there.

### Stats
- `stats:getStat(id, true)` — **`true` = unmodified.** With `false` you get the
  value *after* encumbrance penalties, which appears to FALL as the pack fills.
- `stats:xpStat_eventBased(id, amount)` — grants XP; verified to move the
  in-game skill tab.
- IDs: Labouring `3`, Swimming `23`, Perception `24`, Precision Shooting `36`

### Standstill / drift
A character standing still **in water** drifts ~**10–11 world units**
(measured: 10.3 / 10.4 / 10.6 / 11.1). Any "has the character moved" tolerance
below that fires constantly on a stationary character.

---

## 5. Money
```lua
character:getOwnerships():addMoney(n)   -- see tools: 90_devcash.lua
```
`getMoney()` / `takeMoney(n)` exist on Character, Inventory, ContainerItem,
Ownerships, RootObject, ShopTrader, UseableStuff. `addMoney`/`setMoney` are on
**Ownerships** only.

---

## 6. Events / timing
- `registerHandler("onCharsUpdate")` — the sim tick, fires **~100/sec**
  (measured: a "3s" cast completed in ~0.9s under a 30/sec assumption)
- `registerHandler("onKeyDown")` — keycode arrives as something whose
  `tostring()` is the scancode; `33` = F, `34` = G
- **F is bound to centre-on-character in vanilla** — it double-fires. G is free.
- Handlers survive a script reload. Track handles and unregister, **and** use a
  generation counter — handlers registered before the guard existed are
  untrackable and immortal until a full restart.

---

## 7. The character-freeze bug (#21 / #37) — LIKELY RESOLVED

> **Resolution (2026-08-02).** Greg's call — *"i 100% dont think its exp i think
> 100% its inventory"* — was correct. Switching the stop condition from
> `hasRoomForItem` (a **grid probe**) to `getNumItems()` (a **plain count**), and
> halting 10 catches into a load, stopped the freeze.
>
> **The trigger was our own interaction with a saturated inventory**, not any
> item we created. The previous guard stopped auto-fishing *at* the boundary but
> still probed it, and the last recurrence landed on the exact cast that first
> hit `hasRoomForItem=false`.
>
> **Rule for every future system that grants items** (cooking, trade, loot):
> stop on a **count**, well short of saturation. Never probe a full grid.
>
> This is avoidance, not root cause — what Kenshi does internally when a script
> queries a saturated inventory is still unknown.

### Original investigation (kept — it is the record of what was eliminated)

**Symptom.** Character stops taking orders; inventory will not open; stats screen
flashes open and closes; **the world keeps running normally**. No error is ever
logged. Recurs at **inventory saturation**.

### Ruled OUT by evidence
| Theory | Killed by |
|---|---|
| Malformed junk item | Reproduced with several different items |
| Orphaned item from a failed mint | Freeze occurred when **every grant was refused** — nothing was created |
| `addItem` double-registration | Duplication had already stopped in a run that still froze |
| Drop-into-water (`dropOnFail`) | Already `false`; freeze still occurred |
| Deterministic "cast 4 item" | Was unseeded RNG replaying a sequence, not a specific item |
| XP writes | Reproduced once with `ALLOW_XP=false` — **but see below** |

### Still live
On a full pack, per cast, the **only engine write** is:
```lua
stats:xpStat_eventBased(id, amount)   -- x4
```
Everything else is a read. The 2026-08-02 19:55 freeze happened on a cast where
the grant was **refused** (no mint) but **XP was granted**, then auto stopped
cleanly — and the character still froze.

The earlier XP-off freeze *did* mint items successfully, so it may have been a
**different** failure. Two distinct bugs would explain why no single-cause theory
has covered all the evidence.

**Remaining candidates:**
1. `xpStat_eventBased` on a character whose pack is full
2. `hasRoomForItem` on a saturated inventory (a read, but one whose behaviour
   provably changes exactly at the boundary where the freeze happens)
3. Something in Kenshi itself about full inventories, unrelated to our writes

### Next experiment
Fill a pack, then `Fishing.setXp(false)` and keep casting into it. If it still
freezes with **no mint and no XP write**, the cause is a *read* — which would be
a far stranger and more important finding.
