# FCS Session 1 — Raw Fish + cooking sink

First content session. **You drive FCS; I can't** — it is a GUI editor with no scripting hook. My job here is the spec, and interpreting whatever you hit.

> **Honest caveat:** I know FCS conceptually, not menu-by-menu. Where I say "find X", explore and tell me what you actually see — I'd rather adjust than invent a menu path that doesn't exist.

## Before you start

**Close Kenshi.** FCS and the game should not hold the data at once.

Launch: Steam → Kenshi → **Launch Modding tool** (or `D:\SteamLibrary\steamapps\common\Kenshi\forgotten construction set.exe`).

## What we know from the live game

| Fact | Value |
|---|---|
| Only fish item that exists | `Dried Fish` — category 4, stringID `50518-Newwworld.mod` |
| Raw Meat (our stat anchor) | category 4, stringID `42243-rebirth.mod` |
| Item categories | 2 = weapons · 3 = clothing/armour · 4 = food/materials |
| Fish icons available | ~3 in the game files (per Greg) — art exists to reuse |

## Goal

Fishing currently grants `Dried Fish` directly, which is **free money** — no cost, no risk. The sink you designed:

```
catch RAW fish  →  must COOK it  →  chance to BURN  →  edible/sellable
```

## Task 1 — create the mod

Create a **new mod** in FCS named something like `KenshiOverhaulSuite`. Everything below goes in it, so it stays separate from vanilla and from KenshiLua.

Note the `.mod` filename it produces — I'll add it to `data/mods.cfg` so the game loads it.

## Task 2 — Raw Fish item

**Easiest route: clone `Raw Meat` rather than build from scratch** — it already has the right shape (food, category 4, edible, spoils).

Then change:

| Property | Value | Why |
|---|---|---|
| Name | `Raw Fish` | what our Lua looks up by name |
| Nutrition | **15** | your spec, matches Raw Meat |
| Value | **~c.30** | your spec |
| Weight | **1 kg** | your spec |
| Edible raw | **NO** | forces the cooking step |
| Icon/mesh | one of the fish assets | art already exists |

⚠️ **The name must match exactly** — our script does `getDataByName("Raw Fish", 4)`. If you name it differently, tell me the exact spelling.

## Task 3 — cooking recipe

Raw Fish → cooked output, at whatever building vanilla uses for food prep (Cooking Stove / Campfire — check what `Foodcube` or `Cooked Meat` use as a template).

Output could be `Dried Fish` (already exists) or a new `Cooked Fish`. **Reusing Dried Fish is less work** and perfectly reasonable.

## Task 4 — burn chance

The risk half of the sink. If FCS recipes don't support a failure chance natively, **tell me** — I can implement burning in Lua by hooking the crafting event instead. Either way the design survives.

## Deferred (your call)

- **Spears** — deferred to a final pass over the whole system
- Rods, docks, the fishing job animation — later FCS sessions

## When you're done

Tell me:
1. The exact **item name** you used
2. The **.mod filename**
3. Whether burn chance was possible in FCS

I'll wire the Lua to grant Raw Fish instead of Dried Fish, register the mod, and we test the full loop.
