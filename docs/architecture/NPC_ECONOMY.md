# NPC Economy — mod-owned characters, worked resources, a fluid economy

## Problem (Greg, 2026-08-12)

Vendors spawn goods from nothing — no production backs their stock. Nothing
in the world is physically worked except the Empire's slave mines, which is
the one thing that already reads right. Hivers get no economic identity.
Cities have no food chain at all. Every loop this project ships today
(fishing, cooking, hauling) is 100% player-driven: nothing runs when the
player isn't standing there pressing a key. That's the actual gap between
"scripts that work" and "a mod."

## Design principles — ported as PATTERNS from StarFall, not code

Source: `D:\StarFall\Source\StarFall\NpcV2\WaypointSites.h`, `Founding.h`,
`Common\WaypointJobLifecycle.h`. StarFall's actual implementation (WAL
conservation contracts, SHA-1 identity derivation, replay-safe reservation
IDs) is enterprise-scale engineering for 2000+ NPCs with Unreal SaveGame
crash recovery — the same over-scaling WSM.md's own header already warned
against porting wholesale ("almost none of it belongs here"). What DOES
translate, at Kenshi's actual scale:

1. **Authored sites, not computed ones.** StarFall's founding bug (a farm
   spawned directly on top of a hand-built tent city) came from asking "is
   this point valid" instead of "is this a place a waypoint belongs."
   Site locations should be a curated table someone actually placed, not a
   formula. In Kenshi there's no level editor to place trigger volumes in —
   the equivalent is a hand-picked table of real map coordinates near real
   resource features, authored by walking the map, not computed from a
   proximity search.
2. **Honest block reasons, never silent failure.** Already this project's
   own convention everywhere (`canFish`, `canCook`, `TownEconomy.registerTown`
   all return `ok, reason`) — StarFall's `ENpcV2Reason`/`EBlockReason` enums
   are the same idea at a different scale. Keep doing exactly what this repo
   already does; no new machinery needed here.
3. **Conservation-first.** `Items.verify()` already enforces this
   (08_items.lua) — a physical producer just needs to call `Items.bank`
   the way Fishing/Cooking already do. Nothing new to build; wire the new
   producer into what exists.
4. **Demand-driven growth, capped.** StarFall founds a new waypoint only
   when unsatisfied demand crosses a threshold, capped per town, sited near
   an actual resource cluster with standoff (not on top of it). Same shape
   is a natural extension of `TownEconomy` (#48), which already tracks
   per-town stock and specialty — it just doesn't yet grow the WORLD in
   response to that stock, only the numbers.
5. **Mod-owned bodies, not vanilla-NPC hijacking.** The biggest departure
   from what this project tried first. `getSelectedCharacter()` can only
   ever return a squad member (confirmed live, SPINE.md), so fighting
   vanilla's selection system to drive an *existing* townsperson is a
   losing fight. Spawning our own characters via
   `RootObjectFactory:createRandomCharacter`/`createRandomSquad`
   (30_spawn_probe.lua) means we hold the Lua reference from creation —
   no selection step, no ambiguity, ever.

## The embodiment layer

A mod-owned NPC is a character we spawned and hold a direct reference to,
not one we found and are trying to command. This sidesteps the
selection problem entirely, but does NOT yet answer whether `addJob`/
`addGoal` reliably drives behavior on it — that's still an open question for
ANY target, vanilla or spawned (see SPINE.md's retraction of the earlier
overclaimed "milestone").

**Fallback that already works if native jobs don't pan out:**
`Character:relocationTeleport` is confirmed live (SPINE.md, 2026-08-11) —
a direct-manipulation tick loop (read state, decide, move/act, same shape
as `Fishing`'s `rearmIfAuto`) is a real, already-proven path that does not
depend on `addJob` working at all. Worth stating explicitly so this plan
does not collapse if the native-job route has a ceiling: there is a
fallback, and it is not hypothetical.

## Site model

A site is `{ siteKey, kind, cityKey, position, radiusCm }`. `kind` ∈
`woodcutter | miner | farmer | fisher | hunter` (mirrors both StarFall's
taxonomy and Kenshi's real gathering trades — no invented categories).
Claim/lifecycle tracking extends WSM's existing `settlements` category
(same shape `TownEconomy` already uses for per-town records) rather than a
second parallel store.

**This needs Greg, not guesswork:** the site table itself has to be
authored against Kenshi's real map — actual ore-vein locations, real
farmland, real shoreline, per city/region. I don't have that knowledge and
won't fabricate coordinates. A short list of "near which real city, roughly
what resource" is enough to start; exact placement can be tuned live the
same way `BAR_HEIGHT`/`moveToleranceSq` were tuned from measured logs
elsewhere in this project.

## Worker lifecycle (simplified from StarFall's Founding→Ready→Active→
Blocked→Retired — same idea, no WAL, no cryptographic identity, because
Kenshi's scale and lack of Unreal-grade save/crash guarantees don't need
that machinery)

```
Idle       -- site exists, no worker assigned
Assigned   -- worker spawned/bound, en route
Working    -- producing on a tick, writes through Items.bank (same call
              shape Fishing.tryCatch/Cooking.cook already use)
Blocked    -- reason string (no worker / site contested / unreachable /
              addJob refused) -- same `ok, reason` convention as the rest
              of this repo, not a new pattern
Retired    -- worker died or was removed; site returns to Idle
```

## Regional identity — extending TownEconomy (#48), not replacing it

`20_town_economy.lua`'s own header already states its stock growth is
**abstract by design** — "no physical NPC ever shown mining anything" —
specifically because the labor-abstraction layer (this document) didn't
exist yet. The natural next step is NOT a rewrite: a Working site's
production tick feeds the SAME `settlements.stock` `TownEconomy` already
tracks, so the numbers trace to a real spawned body instead of a flat
daily grant. Existing `TownEconomy.verify()`/`.selftest()` invariants keep
applying unchanged.

**City food chain**: nothing today produces food into a city's own stock —
`farmer`-kind sites + spawned farmer NPCs closes that gap directly, the
same shape as the ore/iron/copper specialty resources already modeled.

**Hivers**: flagged as genuinely open. I don't have specific Hive-faction
economic-identity knowledge to design against without guessing, and I'd
rather say that plainly than invent lore. What does Greg want hivers to
economically DO differently from human towns?

## What's buildable in Lua now vs. what needs Greg

**Buildable now, no blockers:**
- Site table schema + WSM-backed claim/lifecycle tracking
- Production tick wired into `Items`/`Storage` (same shape as
  `Fishing.tryCatch`/`Cooking.cook` — not a new pattern, a new caller)
- `TownEconomy.processDay` extended to read physical production alongside
  (or instead of) its current abstract grant

**Needs Greg:**
- Real site coordinates (per city, per resource kind)
- Hiver-specific economic design intent
- Whether FCS custom job types are viable at all (#39's still-open Q2)
- Confirming, live, whether `addJob`/`addGoal` actually drives a SPAWNED
  character's behavior (the one thing 30_spawn_probe.lua doesn't yet
  answer — it stops at "does the character exist and respond to reads")

## Phased plan

1. **Next live session:** run `30_spawn_probe.lua` — prove a mod-owned
   character can be created and read back at all. This is the load-bearing
   unknown everything else depends on.
2. Test `addJob`/`addGoal` against the SPAWNED character specifically —
   the cleanest possible target, zero squad/selection confound, zero
   coincidental-timing risk if the test task has an unambiguous effect
   (walking somewhere, not "stood up").
3. If that works: wire ONE real site + ONE spawned worker + one production
   tick into `Items`/`Storage`, and prove the physical-to-ledger trace end
   to end before scaling to a second site.
4. If `addJob`/`addGoal` doesn't reliably drive it: fall back to the
   direct-manipulation tick loop (confirmed-working `relocationTeleport`),
   same shape as `Fishing`'s `rearmIfAuto` — a real path, not a hope.
5. Scale: multiple sites per city, city food chains, `TownEconomy`
   specialty backed by physical sites instead of an abstract-only grant.

This is a first draft, not a locked design — the whole point of writing it
down is to react to it, not to freeze it.
