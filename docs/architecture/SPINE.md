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
   (native access violation, not a Lua error).
   ⚠️ **"All container-typed members are excluded" was FALSE.** `gen_probes.py`
   Rule 5 blocklists doc *strings*, but the docs record **element** types — so
   `Character.disguiseGUIFeedbacks` (documented `integer`),
   `Character.whoSeesMeSneaking` (`hand`), `Character.activeEffects` (`integer`)
   and `Inventory.sections` (`InventorySection`) all passed the filter and were
   read live. They returned `table:`. **We survived four reads of the crash class
   by luck on one run.** Rule 5 must become an **allowlist** of known scalars.
3. **`swimming` and `getWaterLevel()` disagree.** Observed live: `swimming = 1`
   while `getWaterLevel() = 0` — and later `swimming = 12.91` while standing on
   **dry land**. `swimming` is a **lagging accumulator**, not a boolean and not a
   depth. **`getWaterLevel()` is the trustworthy signal** (0 land / 1–2 wading /
   3 deep) and is what the shipped gate uses. *(This line previously asserted the
   opposite; corrected after red-team review found code and doc disagreeing.)*
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

⚠️ **CORRECTION (red-team review).** The absence of `math`/`string`/`table`/`io`
from that list is an **artifact of the probe's own filter**, not a finding: the
enumerator used `if type(v) == "function"`, and standard libraries are *tables*,
so they were structurally invisible. Disproven by shipped code that works —
`math.random`, `table.concat`, `table.sort`, and `("…"):format` are all in use.

`io` is genuinely **untested**, so "the log is our only output channel" is an
assumption, not a verified fact. Re-run the enumeration without the type filter
to settle it.

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

## OPEN: NPC job/task assignment (the Alive Core / Projector dependency)

**2026-08-09.** Issues #28, #33, #34 all cite `onCharacterAddJob`/`AddOrder`/
`AddGoal` as "verified hooks" enabling NPC-driven jobs (town production, road
traffic, slavery tasks). They are not verified — that name does not appear
anywhere in this repo's actual probe output (`_probe_raw.txt`, 498/500 API
surface tested 2026-08-01) or in `probe_manifest.lua`'s safe-callable set.
It came from the (known-unreliable) bindings doc, not from a probe run.

**What IS real, found by cross-referencing the raw bindings doc against the
actual C++ headers in `third_party/KenshiLib`** (static analysis only — NONE
of this has been called live):

- `Character:addJob(t, shift, addDontClear, location)` — per
  `third_party/KenshiLua/docs/BindingsReference.md`.
- **But the real C++ signature disagrees with that doc**, per
  `third_party/KenshiLib/Include/kenshi/AI/AITaskSystem.h`:
  `void addJob(TaskType t, const hand& subject, const Ogre::Vector3& location, bool shift)`
  — argument COUNT matches (4), but the TYPE and ORDER of args 2-4 do not:
  the doc says `(shift: boolean, addDontClear: boolean, location: Vector3)`,
  the header says `(subject: hand, location: Vector3, shift: boolean)`.
  This is exactly the failure class SPINE's headline finding #1 already
  named ("29 more take arguments the docs say they don't") — now with a
  concrete example for the single most load-bearing call in the roadmap.
- Sibling calls, same file: `addOrder(t, shift, clear, location)` (doc) vs.
  `addOrder(TaskType t, const hand& subject, const Vector3& location, bool clear, bool shift)`
  (header — 5 args, doc only lists 4). `addGoal(t)` — doc and header agree
  (1 int arg) and this is the lowest-risk of the three to test first.
- `removeJob(t)`, `getPermajob(slot)`, `getPermajobData(slot) -> Tasker`,
  `getPermajobCount()` also exist. **`getPermajobCount()` takes zero args and
  IS in the safe-callable manifest** (`probe_manifest.lua` line ~381) — this
  one can be read live with no more risk than any other verified zero-arg
  getter already in daily use.
- The real `enum TaskType` (`third_party/KenshiLib/Include/kenshi/Enums.h`,
  291 entries, 0-indexed) is fully enumerated. Task ids directly relevant to
  the roadmap: `NULL_TASK=0`, `IDLE=14`, `WANDERER=24`, `MOVE_CUS_ORDERED=29`,
  `HOLD_POSITION=30`, `PATROL_TOWN=36`, `WANDER_TOWN=37`,
  `FOLLOW_PLAYER_ORDER=44`, `RECRUIT_AT_JOBCENTER=55`, `STAND_STILL=62`,
  `OPERATE_MACHINERY=87`, `DELIVER_RESOURCES=88`, `COLLECT_OUTPUT_RESOURCE=92`,
  `FIND_A_SHOP=117`, `SHOPPING=118`, `BUY_SHIT=119`, `JOB_BUILDER=125`. If any
  of `addJob`/`addOrder`/`addGoal` actually work, `OPERATE_MACHINERY` /
  `COLLECT_OUTPUT_RESOURCE` / `DELIVER_RESOURCES` are the exact engine-native
  task shape #40's mining-window pattern already described — worth trying
  before inventing a Lua-side equivalent.

**Route to test, in risk order (safest first):** read `getPermajobCount()`
live (zero risk, same as any other verified getter) → try `addGoal(TaskType)`
with `IDLE` or `WANDERER` on a deliberately disposable, non-squad NPC (1 int
arg, lowest surface area) → only then attempt `addJob`/`addOrder`, trying the
C++ header's argument shape first since it is the primary source, with each
variant behind its own pcall AND a log line printed BEFORE the call (the
`01_capability_probe.lua` LOG-AS-CURSOR discipline — pcall does not catch a
native access violation, so the log is the only thing that survives a crash
and names the killer). See `mods/suite_scripts/scripts/27_projector_probe.lua`.

Until this is run live and harvested back into this file, #28/#33/#34's
"verified hooks" claim should be read as "found in a header," not "proven."

### UPDATE 2026-08-10: found the real signature, and it's safer to test than feared

Neither the doc nor the header check above had looked at
`third_party/KenshiLua/docs/CallbacksReference.md` — a dedicated event-
callback reference, separate from `BindingsReference.md` (methods/fields
only), that nothing in this project had read yet. It resolves the addJob
question with much higher confidence than either prior source, straight from
the compiled hook's own C++ dispatcher signature:

```
void CallCharacterAddJobCallbacks(Character* character, int task,
    RootObject* subject, bool shift, bool addDontClear, const Vector3& location)
```

i.e. the real call is **`addJob(task, subject, shift, addDontClear, location)`**.
`BindingsReference.md`'s doc entry was not simply reordered — it was MISSING
the `subject` parameter entirely, which is why any doc-shaped call was
guaranteed to fail regardless of argument order. `27_projector_probe.lua`'s
Phase 3 now tries this shape first (Variant A), then the AITaskSystem.h
header's shape (Variant B, a plausible different overload), then the doc's
incomplete shape last (Variant C, kept only because "known incomplete" still
beats "untried").

**Same reference also confirms `onCharacterAddJob`, `onCharacterAddOrder`,
and `onCharacterRemoveJob` are real, and — critically — they are
NOTIFICATION/OBSERVER hooks, not things we call.** They fire whenever ANY
code, including the game's own vanilla AI, invokes the real
addJob/addOrder/removeJob. That makes a genuinely zero-risk investigation
possible that did not exist before: register these three hooks and watch
what TaskType values the engine assigns to real NPCs during ordinary,
unmodified play — e.g. watch a farmer for a few minutes and read the actual
TaskType sequence behind the wheat loop off the log, instead of guessing at
it from FCS. `Projector.startObserve()` / `.stopObserve()` in the same probe
file. Cannot crash anything — it never calls into the engine, only reacts to
what the engine already decided to do on its own.

**Also worth checking against this same reference before trusting ANY other
"verified hooks" claim in the open issues** — a spot-check across #26
(`getWaterLevel`/`calculateSwimSpeed`), #29 (`onDialogueCheckCondition`), #31
(`onPlayerStealCheck`/`onSmugglingTradeCheck`/`onGetFencingChance`/
`stealthMode`/`_lightLevel`), and #32 (`isMySlave`/`isMyFactionsSlave`/
`onCharacterFactionChanged`/`onCrimeWitnessed`) done 2026-08-10 found all of
them real and present in `CallbacksReference.md` or the live probe run — so
#34 was the one bad claim in the set, not a sign the others need the same
correction. `isMySlave`/`isMyFactionsSlave` are a smaller, separate finding:
`_probe_raw.txt` shows them erroring with "Character expected, got no
value" — they are real methods that need an argument the zero-arg safe
sweep never supplied, and the doc's `` (empty) argument column for them is
therefore ALSO wrong, same failure class as addJob, just lower stakes.

## VERIFIED live 2026-08-10: equipment slot names + another arg-order bug

First real payload from `28_vanilla_observer.lua`'s bulk-scrape session (LIFE
tag, ~4 real minutes at 20x game speed near a slave camp — game speed
multiplies event volume proportionally, so treat the counts below as ~80
game-minutes of ordinary NPC equip/unequip churn, not an anomaly. Directly
useful for #43 skeleton gear and #44 belt-slot drones):

**Confirmed real equipment slot names** (`onCharacterEquip`/`onCharacterUnequip`'s
slotName argument, 1510 firings observed): `legs`, `back`, `armour`, `shirt`,
`head`, `boots`, `hip`, `hands`, `main`. No longer a guess for #43/#44 — these
are the actual strings the engine uses.

**Another doc-vs-reality argument-order bug**, same failure class as addJob:
`CallbacksReference.md` documents `onCharacterEquip`/`onCharacterUnequip` as
`function(character, item, slotName)`. The observed live data is unambiguous
that the real order is **`(character, slotName, item)`** — every observed
line showed a short lowercase slot string in position 2 and a
`KenshiLua.Item object` in position 3, never the reverse, across 1510
samples. Treat `CallbacksReference.md`'s argument ORDER columns with the same
skepticism `BindingsReference.md`'s already earned — the events themselves
are real (that part has held up every time it's been checked), the
documented argument order is what keeps being wrong.

**Operational note for future bulk-scrape sessions:** run a new tag group at
1x game speed first. High-frequency events (equip/unequip here) can generate
enough synchronous log-file writes in a tight burst to plausibly cause an
input hitch (an M-key press not registering was observed in the same
session) — not a crash, but real overhead. `28_vanilla_observer.lua` now
rate-limits after the first 3 occurrences of each event to a periodic count
line; `Observer.counts()` gives the full tally regardless.

## VERIFIED live 2026-08-11: Character:relocationTeleport works, real unstuck fix

`Character:relocationTeleport(moveBy: Vector3)` — first live call, confirmed
working. `Vector3` in this binding is a plain Lua table (`{x=.., y=.., z=..}`,
matches `CallbacksReference.md`'s own `setHoldLocation` note calling its
Vector3 arg a "vector3Table" — no dedicated Vector3 userdata class exists in
`BindingsReference.md`). `moveBy` is a **relative offset**, not an absolute
position, matching the parameter name — a small vertical nudge
(`{x=0, y=0, z=300}`) on `getSelectedCharacter()` is a working practical fix
for an NPC stuck in geometry, no need to know their target coordinates.
`Character` also exposes `teleport(moveBy: Vector3, rot: Quaternion)` (same
class, untried) if a relative move alone is not enough.

## VERIFIED live 2026-08-12: addGoal's real signature — first working write

**Resolves the biggest open question in `27_projector_probe.lua`'s header:
can Lua actually drive a character through a task, or was "verified hooks"
in #28/#33/#34/#46/#49 just a doc claim never run?** First confirmed-working
write call:

```
character:addGoal(taskId, character:getHandle():getRootObjectBase())
```

`BindingsReference.md` documents `addGoal(t: integer)` as single-arg — wrong,
same failure class as `addJob`'s missing `subject` param and
`onCharacterEquip`'s swapped arg order (three confirmed instances of this
project's one recurring doc failure mode now). The real binding requires a
second `RootObjectBase`-typed argument. `getHandle()` alone is NOT enough —
it returns a `hand`, a different type, and errors
`"RootObjectBase expected, got userdata"`. The working chain unwraps one
level further: `Character:getHandle()` → `hand` → `hand:getRootObjectBase()`
→ `RootObjectBase`, which `addGoal` accepts. `nil` (both omitted and
explicit) is rejected outright — a real subject object is mandatory, no nil
shortcut for a targetless task like IDLE.

Tested live on the **player character** (with a fresh save as the safety
net, not a disposable NPC — the probe's own default caution). Call itself
returns cleanly with zero error and zero crash.

**Behavioral result: no observable effect.** The player character had been
running before the call and kept running through it, uninterrupted — despite
IDLE (task 14) being the lowest-consequence task in the enum specifically
because a character told to idle is supposed to look close to doing nothing,
not literally identical to whatever it was already doing. This does NOT mean
`addGoal` is a no-op — it's confounded by testing on a player-POSSESSED
character, where held movement input very plausibly re-asserts every frame
and masks any AI-goal effect regardless of whether the goal was actually
applied underneath. The call executing cleanly is real evidence the write
path works; this specific result says nothing new about whether AI goals
route around active player input, only that IDLE-while-actively-running
produced no visible change. Next step for a clean signal: retest on an
actual disposable, non-player-controlled NPC (the probe's original design
target) where there is no competing input to mask the result either way.

**CORRECTION 2026-08-12:** the two retests below were described as "on a
disposable NPC" — wrong. Greg confirmed both were actually still one of his
own controlled main characters (a squad member), not an independent
townsperson going about autonomous vanilla AI business. That means neither
result actually eliminated the control confound noted above — a squad
member is still plausibly player-adjacent (squad orders / player command
authority), just one level removed from direct WASD input. Left the
original wording below uncorrected-in-place (matches this project's own
practice of flagging a wrong claim rather than silently rewriting history),
but treat both "no visible change on a disposable NPC" claims as UNPROVEN
until retested on a genuinely independent NPC (a random townsperson/guard
with zero squad relationship) — the probe's real original design target.

**Retested 2026-08-12 on a disposable NPC — still no visible change,** but
now the player-input confound is gone (5 back-to-back calls, all clean:
"returned (no error)" x5, zero crash, zero hang — the write path is
demonstrably reliable across repeats). IDLE's design point of looking close
to doing nothing cuts both ways: great for confirming this call causes no
harm, bad for confirming it causes anything at all. A "no visible change"
result on a task specifically designed to be invisible is weak evidence
either way. Next step: retest with `WANDERER` (task 24) instead — still one
of the two lowest-consequence tasks in the enum, but should produce an
unmistakable visible effect (the NPC should start walking somewhere) if
`addGoal` genuinely drives behavior end-to-end.

**WANDERER retest, same confound:** `addGoal(24=WANDERER, ...)` returned
clean, zero error, zero crash (dump timestamp unchanged). Real side effect
observed: a genuine frame drop/game-wide slowdown at the moment of the
call — not a crash, but real engine cost, plausibly the game synchronously
computing a destination + nav path for the wander task. That is meaningful
corroborating evidence the call engaged real AI/pathfinding machinery
(unlike IDLE's total silence), independent of the control-confound question.
After the hitch passed, the character just continued what it was already
doing — no lasting behavior change. Still needs a genuinely independent NPC
retest to settle whether the lack of a lasting change is `addGoal` being
overridden by squad/player command authority, or `addGoal` genuinely not
producing persistent behavior change on its own.

**"Genuinely independent NPC" retest, 2026-08-12 — CORRECTION, this was not
actually independent.** Originally logged as `addGoal(24=WANDERER, ...)` on
a wild bonedog with zero squad/player relationship. That was wrong: every
target in this whole investigation, including the bonedog, went through
`getSelectedCharacter()`, which reads `PlayerInterface.selectedCharacter` —
Kenshi's SQUAD ROSTER selection, not a world click-target (see the dedicated
correction entry further down). Clicking an arbitrary NPC does not set that
property; only selecting one of the player's own characters does, and a
tamed animal counts as squad. The bonedog was therefore very likely a tamed
pet in Greg's own squad, not independent wildlife — the control-authority
question these three "targets" were meant to settle was never actually
tested. Left the original result below for the record (no crash, no
observable change, matches the pattern), but its "genuinely independent"
framing does not hold.

Across three attempted targets (player, squad member, presumed-but-unproven
independent) and two tasks (IDLE, WANDERER), `addGoal` never produced one
confirmed lasting behavioral effect, despite the write path itself being
completely reliable (every call returns clean, zero errors after the
signature fix, zero crashes across ~10+ live calls total). `addJob` (Phase
3, takes an explicit `location` argument) is the next candidate — a much
more forceful, directly observable command shape if it works.

`addJob`'s `subject` parameter (Phase 3, `CallbacksReference.md`'s dispatcher
shape) was, until now, untested against this same `RootObjectBase` unwrap —
it passed the raw `hand` from `getHandle()`, the same shape that proved
wrong for `addGoal`. Fixed in `27_projector_probe.lua` (`f3458e1`): a new
Variant A tries the `RootObjectBase` unwrap first, ahead of the three
original variants (now B/C/D).

**Live Phase 3 test, 2026-08-12 — `addJob` wants `RootObject`, NOT
`RootObjectBase`.** The two are genuinely separate classes in
`BindingsReference.md`, not the same type under two names. Error text was
unambiguous: `"bad argument #2 to 'addJob' (KenshiLua.RootObject expected,
got userdata)"` for both the raw-hand and `RootObjectBase`-unwrap attempts;
the doc-shape variant (which puts `false` in that slot) errored `"expected,
got boolean"` — same slot, same required type, regardless of shape. Fix
(`61bc259`): `hand` has `getRootObject()` sitting right next to the
`getRootObjectBase()` that solved `addGoal` — Variant A now uses the correct
one. **Process note:** this test initially ran against a STALE in-memory
copy of the probe script (Kenshi wasn't re-`dofile`'d after the latest
deploy) — the log's own variant labels gave it away (old wording, not the
newly-edited text), which is why label text doubles as a version check, not
just documentation.

**MILESTONE, 2026-08-12 — first confirmed behavioral effect from any
Projector write call.** Retested with the fix live: `addJob(24=WANDERER,
subject:RootObject, false, false, pos)` via corrected Variant A returned
clean (zero error, zero crash, dump timestamp unchanged) — AND this time
something real happened. The character (sitting) was interrupted, stood up,
and talked. A genuine state transition, not a hitch or silence. This is
qualitatively different from every `addGoal` result above: across three
targets and two tasks, `addGoal` never once interrupted existing behavior;
`addJob` did, on the first clean attempt with the right subject type. Real
evidence `addJob` carries command authority `addGoal` does not.

Same caveat as the earlier `addGoal` retests applies here too: this was on
Dreadnaut (Greg's own squad member), not a fully independent NPC, so the
squad-authority question isn't settled — worth one more retest on a truly
independent target (the bonedog shape) to fully close it out. The specific
resulting behavior (talking, not literally walking to a WANDERER
destination) most likely means the call broke the character out of its
sitting state and its own AI then picked the next action, rather than the
engine obeying the WANDERER destination directly — plausible, not proven.
Either way, this answers the probe's original headline question in the
affirmative for the first time: **Lua can drive a character through a real,
observable behavior change via `addJob`.**

## FOUND LIVE 2026-08-12: getSelectedCharacter() can only ever return squad

`getSelectedCharacter()` reads `PlayerInterface.selectedCharacter`
(`BindingsReference.md` line ~7237: `selectedCharacter | hand | RW`), which
is Kenshi's **squad roster selection** — whichever of the player's own
characters is currently active — not a world click-target. Clicking an
arbitrary townsperson in the world does not set this property; only
selecting one of the player's own characters does (a tamed animal counts as
squad). Every Phase 1/2/3 test run through this getter, all session,
targeted a squad member, no exceptions, regardless of what was actually
clicked in the world. This invalidates the "genuinely independent NPC"
framing applied to several earlier results above (see the bonedog
correction) — the squad/command-authority confound was never actually
eliminated by any test run before this fix.

**Fix (`07f4c59`):** Phase 0's notification hooks (`onCharacterAddJob` /
`onCharacterAddOrder` / `onCharacterRemoveJob`) already receive a live
`character` argument for ANY character the game's own AI acts on, squad or
not. `startObserve()` now stashes the most recently observed one in
`Projector._lastObserved`; `Projector.lastObserved()` reports who;
`testGoal`/`testJobOrder` take a new optional second argument — pass `true`
to target the capture instead of `getSelectedCharacter()`. This is the
first actual path to a genuinely independent-NPC test in this whole
investigation. Not yet exercised live — next retest should use it to
finally settle the squad-authority question cleanly.

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

## The item mint→grant chain (2026-08-01)

> **Calibration (red-team):** these were reconstructed from argument errors,
> which establish **arity and parameter TYPES only**. The parameter *names*
> below are INFERRED -- nothing has verified that arg 2 of `addItem` is a
> quantity, or that arg 5 of `createItem` is a level rather than a quality or
> condition index. Treat the names as hypotheses until tested (e.g. grant
> `addItem(item, 3, ...)` once and count with `countItems`).

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
