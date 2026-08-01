# FCS Session 1 — first pass, 4 items

**Scope: 4 items.** Enough to prove the entire catch → cook → burn sink end to end.
The other ~8 exotic tiers get bulk-added once the loop is validated. Same
vertical-slice logic that worked for the Lua half: prove the chain, then widen.

> **Honest caveat:** I know FCS conceptually, not menu-by-menu. Where this says
> "find X", explore and tell me what you actually see — I would rather adjust
> than invent a menu path that does not exist.

## Before you start

**Close Kenshi.** Launch: Steam → Kenshi → **Launch Modding tool**
(or `D:\SteamLibrary\steamapps\common\Kenshi\forgotten construction set.exe`).

## Already in vanilla — do NOT author

| Item | Cat | stringID |
|---|---|---|
| `Thinfish` | 4 | `50517-Newwworld.mod` |
| `Dried Fish` | 4 | `50518-Newwworld.mod` |
| `Crab` | 7 | `56089-Newwworld.mod` |
| `Raw Meat` | 4 | `42243-rebirth.mod` — **our clone source** |

(`Grand Fish` appears to have been removed from the game — Greg confirmed via forum.)

## Step 1 — create the mod

New mod in FCS, name it `KenshiOverhaulSuite`.
**Tell me the `.mod` filename it produces** so I can add it to `data/mods.cfg`.

## Step 2 — the four items

Clone **`Raw Meat`** each time (already the right shape: food, category 4,
spoils, edible), then retarget:

| # | Name (EXACT) | Nutrition | Value | Weight | Edible raw? |
|---|---|---|---|---|---|
| 1 | `Raw Fish` | 15 | c.30 | 1 kg | **NO** |
| 2 | `Small Fish` | 8 | c.15 | 0.5 kg | **NO** |
| 3 | `Cooked Fish` | 30 | c.45 | 1 kg | yes |
| 4 | `Burnt Meat` | 3 | c.2 | 1 kg | yes |

⚠️ **Names must match exactly** — the Lua does `getDataByName("Raw Fish", 4)`.
Different spelling is fine, just tell me what you used and I will change the script.

## Step 3 — cooking recipes

Find how vanilla cooks food (look at what `Foodcube` or a Cooked Meat item uses
as its crafting recipe / building) and copy that pattern:

- `Raw Fish` → `Cooked Fish`
- `Small Fish` → `Cooked Fish`

## Step 4 — burn chance

The risk half of the sink: a cook sometimes yields `Burnt Meat` instead.

**If FCS supports a failure chance / secondary output — use it.**
**If it does not — tell me.** I can implement burning in Lua by watching for the
crafted item and swapping it, so the design survives either way.

## Step 5 — icons (AFTER the items exist)

Kenshi icons are **PNG** in `data/icons/`, named by **stringID** — so the item
must exist first.

1. In FCS, note each new item's stringID
2. Export the matching texture from Unreal as **PNG**
3. Name it to match the stringID pattern, drop it in `data/icons/`

| Item | Your source texture |
|---|---|
| Small Fish | `T_Nhance_Fish_02` |
| Cooked Fish | `Cooking_47_fish_ready` |
| Raw Fish | pick a plain fish |
| Burnt Meat | any charred/meat icon |

Icons are cosmetic — **the loop works without them**, so do this last and don't
let it block testing.

## When you're done, tell me

1. The **`.mod` filename**
2. The exact **item names** (if any differ from above)
3. Whether **burn chance** was possible in FCS

Then I flip the Lua from granting `Dried Fish` to granting `Raw Fish`/`Small Fish`,
register the mod, and we test the full sink in game.

## Expansion (session 2, after this works)

Chum · Sick Fish · Dead Fish · Strange Fish · Brilliant Fish · Octopus ·
Calimari · Cooked Calimari · Cooked Crab · Sushi · Robot Fish — full table and
costing in [`systems/fish_item_table.md`](systems/fish_item_table.md).
