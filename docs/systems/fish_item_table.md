# Fish item table — FCS authoring spec

Greg's catch table, costed so the loop is **not** a money printer.

## Design rules

1. **Nothing valuable is edible raw.** Raw catches must be cooked, which is the time+fuel sink.
2. **Junk tiers dominate the catch.** Chum / sick / dead fish are the common pulls; brilliant/robot are rare.
3. **Existing fish are expensive** (`thinfish`, `grandfish`, `Dried Fish`), so ours slot in *below* them — we are not competing at the top, we are filling the cheap end that vanilla lacks.
4. **Cooking adds value, burning destroys it.** Burnt Meat is the failure sink.
5. **Sushi is the apex** — combines multiple inputs, so its nutrition beats the sum of its parts slightly, rewarding the full chain.

## Anchors (measured in-game)

| Item | Nutrition | Value | Weight |
|---|---|---|---|
| Raw Meat | 15 | ~c.30 | 1 kg |

Everything below is priced relative to that.

## ALREADY IN VANILLA — do not author these

| Item | Category | stringID |
|---|---|---|
| `Thinfish` | 4 | `50517-Newwworld.mod` |
| `Dried Fish` | 4 | `50518-Newwworld.mod` |
| **`Crab`** | **7** | `56089-Newwworld.mod` |
| `Raw Meat` | 4 | `42243-rebirth.mod` |
| `Grand Fish` | ? | spaced spelling still unconfirmed |

**Crab exists**, so we use the vanilla item and need no crab icon. `Thinfish` and
`Grand Fish` are the expensive top tier — ours slot in beneath them.

## ICONS — how Kenshi actually stores them

Measured: `data/icons/` holds **1,609 PNG** files and **zero DDS**. So:

- **Format: PNG.** No DDS conversion; export straight from Unreal.
- **Naming is by stringID**, e.g. `1020-gamedata.base.1059-gamedata.base.png` —
  not by item name.
- **Therefore: create the item in FCS FIRST**, note the stringID it is assigned,
  then name the PNG to match and drop it in `data/icons/`.

Greg's Unreal sources (Nhance RPG Craft Icons / Fantasy Icons Megapack):

| Item | Source texture |
|---|---|
| Small Fish | `T_Nhance_Fish_02` |
| Strange Fish | `T_Nhance_Fish_05` |
| Brilliant Fish | `T_Nhance_Fish_06` |
| Sick Fish | `T_Nhance_Fish_09` |
| Rotten Meat (from Sick Fish) | `T_Nhance_FoodFish_02` |
| Calimari | `T_Nhance_FoodFish_08` |
| Octopus | `T_Nhance_FoodFish_07` |
| Cooked Fish | `Cooking_47_fish_ready` |
| Sushi | `Cooking_42_sushi` |
| ~~Lobster~~ → use vanilla **Crab** | `Res_142_crab` (spare) |

## RAW — caught by fishing (not edible raw)

| Item | Nutrition* | Value | Weight | Rarity | Notes |
|---|---|---|---|---|---|
| **Chum** | 2 | c.5 | 1 kg | common | bottom tier; bait/feed |
| **Sick Fish** | 4 | c.6 | 1 kg | common | possible minor debuff if eaten cooked |
| **Dead Fish** | 5 | c.8 | 1 kg | common | already-spoiled pull |
| **Small Fish** | 8 | c.15 | 0.5 kg | common | the honest low catch |
| **Raw Fish** | 15 | c.30 | 1 kg | uncommon | the Raw Meat equivalent |
| **Calimari** (raw squid) | 14 | c.45 | 1 kg | uncommon | |
| **Octopus** | 18 | c.70 | 1.5 kg | rare | |
| **Crab** (vanilla) | 16 | c.80 | 1 kg | rare | already exists, cat 7 -- no authoring needed |
| **Strange Fish** | 12 | c.60 | 1 kg | rare | oddity; flavour |
| **Brilliant Fish** | 20 | c.120 | 1 kg | very rare | the "good day" pull |
| **Robot Fish** | — | c.150 | 2 kg | very rare | **not food** — scrap/tech |

\* nutrition applies only once cooked, except where noted.

## COOKED — output of the cooking sink

| Item | Nutrition | Value | Weight | Input |
|---|---|---|---|---|
| **Burnt Meat** | 3 | c.2 | 1 kg | **failure product of any cook** |
| **Cooked Fish** | 30 | c.45 | 1 kg | Raw Fish / Small Fish |
| **Cooked Calimari** | 28 | c.75 | 1 kg | Calimari |
| **Cooked Crab** | 32 | c.120 | 1 kg | Crab |
| **Sushi** | 55 | c.180 | 1 kg | **Rice Bowl + (Brilliant Fish OR Crab OR Octopus OR Cooked Fish)** -- a real meal, nutrition at or above Foodcube |

## Why this doesn't break the economy

- The **common** catches (chum/sick/dead/small) are worth **c.5–15**, i.e. less than the time spent — fishing for money is bad money.
- The **valuable** catches are rare *and* require cooking, which costs fuel/time and can **burn**.
- **Burnt Meat at c.2** means a failed cook is a near-total loss.
- Top-end value (Sushi c.150) still sits **below** vanilla `grandfish`/`Dried Fish`, so we never undercut existing content.

## Catch-table weighting (Lua side, not FCS)

Slots into the existing 5% nothing / 80% junk / 15% fish bands. The 15% "fish" band subdivides:

| Tier | Share of the fish band |
|---|---|
| Small Fish | 40% |
| Raw Fish | 30% |
| Calimari | 12% |
| Crab / Octopus | 10% |
| Strange Fish | 5% |
| Brilliant Fish | 2% |
| Robot Fish | 1% |

Chum / Sick Fish / Dead Fish sit in the **junk** band alongside the bottles and bowls, so most casts still yield trash.

Skill shifts junk → fish, so a maxed fisherman pulls the good tiers far more often — the class fantasy again.

## FCS work

Clone an existing food item (Raw Meat is the closest shape) per row, then retarget name/nutrition/value/weight and assign an icon. Robot Fish should clone a **scrap/tech** item instead, since it is not food.

## Icons

Kenshi's art is muted, worn, hand-painted, desaturated — grubby and functional, never glossy. Whatever the source (Fab, Grok Imagine), the icons must read at small size and look **used**.

I cannot view or judge images, so I can't cherry-pick from a pack — but I can write per-item prompt descriptions if that helps, and you decide what looks right.
