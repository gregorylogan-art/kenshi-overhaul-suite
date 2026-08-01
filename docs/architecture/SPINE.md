# Capability Spine — verified Kenshi API surface

**Rule: no system is built against a doc claim. A capability must be ✅ here first.**

`BindingsReference.md` is auto-generated from C++ headers and had never been
executed. This file records what actually happened when we ran it on a live game.

| | |
|---|---|
| Probe run | 2026-08-01, Kenshi 1.0.65 (RE_Kenshi), live save, character swimming |
| Coverage | 498/500 queued probes (99.6%) |
| Results | **450 OK** · 29 wrong-signature · 14 NIL · 4 absent |
| Raw | `_probe_raw.txt` |

## Headline findings

1. **The docs are a hypothesis, and parts of it are false.** Three documented
   methods do not exist at all; 29 more take arguments the docs say they don't.
2. **Container types hard-crash the game.** Reading `lektor<T*>` — as a field
   *or* a method return — kills the process. `pcall` does **not** catch it
   (native access violation, not a Lua error). All container-typed members are
   now excluded at generation time.
3. **`swimming` and `getWaterLevel()` disagree.** Observed live: `swimming = 1`
   while `getWaterLevel() = 0`. **`swimming` is the trustworthy water signal.**
4. **Items are identified by `GameData` objects**, not string ids — deduced from
   the argument errors (`getItem`, `hasItem`, `hasRoomForItem` all demand a
   `GameData`).

## Globals (39) — the real entry points

The README documents only `getGameWorld()`. The full list:

```
getGameWorld  getPlayerInterface  getSelectedCharacter  getInputHandler
getGlobalConstants  getOptionsHolder  getRootObjectFactory  getForgottenGUI
registerHandler  unregisterHandler
assert collectgarbage dofile error gcinfo getfenv getmetatable ipairs load
loadfile loadstring module newproxy next pairs pcall print rawequal rawget
rawset require select setfenv setmetatable tonumber tostring type unpack xpcall
```

⚠️ No `io` and no `math`/`os`/`string` in the function list — file writing is
unavailable, so **the log is our only output channel**.

## Object graph — all verified reachable

```
getGameWorld()          -> GameWorld
getPlayerInterface()    -> PlayerInterface
getSelectedCharacter()  -> Character          <- the "who is acting" hook
  character:getStats()      -> CharStats
  character:getInventory()  -> Inventory
  character:getMovement()   -> CharMovement
  character:getFaction()    -> Faction
getRootObjectFactory()  -> RootObjectFactory  <- likely the item-mint route
```

## Fishing — capability rows

| Need | Binding | Status |
|---|---|---|
| Who is fishing | `getSelectedCharacter()` | ✅ returns Character |
| Am I in water | `CharStats.swimming` | ✅ **= 1 while swimming** |
| Water depth | `Character:getWaterLevel()` | ✅ (read 0 while swimming — see #3) |
| Swim speed | `CharStats:calculateSwimSpeed()` | ✅ = 6.38 |
| Player name | `Character:getName()` | ✅ "Skinner" |
| Player money | `Character:getMoney()` | ✅ = 1000 |
| Input trigger | `onKeyDown(keyCode)` | ✅ **fires** (observed 56, 4096) |
| Sim tick | `onCharsUpdate` | ✅ fires |
| Inventory read | `getNumItems` / `isEmpty` / `getTotalWeight` / `getAllItems` | ✅ |
| **Grant an item** | `Inventory:addItem(...)` | ❓ **OPEN — see below** |
| Play animation | `AnimationClass` | ❌ **unbound → FCS job** |
| Character position | `Character:getPos()` | ❌ does not exist |
| Character health | `Character:getHealth()` | ❌ does not exist |
| Max swim speed | `CharStats:calculateMaxSwimSpeed()` | ❌ does not exist |

## OPEN: the item-grant route

`Inventory:addItem` is documented as `(quantity, dropOnFail, destroyOnFail)` —
no item id, which cannot be right. Given that every sibling call demands a
`GameData`:

```
Inventory:getItem         -> GameData expected
Inventory:hasRoomForItem  -> GameData expected
Character:hasItem         -> GameData expected
```

**Hypothesis:** the real signature is `addItem(gameData, quantity, ...)` and the
docs' argument column is simply unreliable (29 confirmed cases of that).

**Route to test:** `getRootObjectFactory()` and/or
`getGameDataReferenceObject(list, id)` to obtain a `GameData` for an item type,
then feed it to `addItem`. Until confirmed, fishing banks catches in suite state
and reports grant success honestly rather than faking it.

## Danger list — never call these

| Pattern | Why |
|---|---|
| Any `lektor<T*>` / `std::` / `vector<>` / `map<>` member | **hard crash** (confirmed ×2) |
| `_DESTRUCTOR`, `init`, `kill`, `remove`, `save`, `load` | destructive |
| Anything with arguments we cannot fabricate | garbage into a C++ pointer = crash |

Confirmed crashers: `Faction.platoonKillList`, `Faction:getActivePlatoons`.

## Method: how to extend this

1. `python tools/gen_probes.py` — regenerate the safe manifest
2. Deploy `probe_manifest.lua` + `01_capability_probe.lua`, restart, play
3. On crash: the log's last `TRY` line with no result **names the killer** —
   quarantine it (or better, its whole type class) and re-run
4. Harvest results back into this file

Each crash costs one restart and permanently buys one dangerous binding
identified. A crash is a result, not a failure.

---

## SOLVED: the item mint→grant chain (2026-08-01)

Reconstructed **entirely from argument errors** — the documented signatures were wrong at every step.

```lua
-- 1. reach the item database (VALIDATE the route; GameWorld.gamedata resolves
--    but cannot answer queries)
local container = character:getFaction():getData().sourceContainer

-- 2. name an item.  CATEGORIES: 2=weapons  3=clothing/armour  4=food/materials
local gd = container:getDataByName("Dried Fish", 4)

-- 3. mint.  docs said createItem(levelOverride) -- actually:
--    createItem(gameData, hand, gameData?, gameData?, LEVEL:number, Faction?)
local item = getRootObjectFactory():createItem(gd, inv:getHandle(), nil, nil, 0, nil)
--    NOTE: level 0 works for food; WEAPONS return nil at 0 -- try 0/1/-1/2.

-- 4. grant.  docs said addItem(quantity, dropOnFail, destroyOnFail) -- actually:
local ok = inv:addItem(item, 1, true, false)   -- false return = NO ROOM, not an error
```

### Stat IDs (enumerated live, 38 named stats)
`Labouring=3` · `Swimming=23` · `Perception=24` · `Precision Shooting=36`
Read with `stats:getStat(id, false)`, grant with `stats:xpStat_eventBased(id, amount)` — **confirmed visible in the Skills tab**.

### Confirmed vanilla items
`Dried Fish`(4) · `Raw Meat`(4) · `Iron Club`(2) · `Straw Hat`(3) · `Rag Loincloth`(3)
`Sandals` does **not** exist under that name.

### Additional crashers
- `factory:process()` — **hard crash**. Engine internals (`process`/`mainThreadUpdate`/`update`/`run`) are banned; the generator blocklists them and hand-written probes must obey the same rules.

### Reload hazard
`dofile` re-registers handlers, leaving stale script copies running (observed as two divergent tallies and a fixed bug resurfacing). Scripts must track handler ids and unregister before re-registering.
