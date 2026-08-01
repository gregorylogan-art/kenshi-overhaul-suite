# Scope — Canonical systems list

Last updated: 2026-07-29

## 0. Foundation (blocks everything hard)

| ID | Item | Notes |
|----|------|--------|
| F1 | Repurposed dormant-stat skill framework | Fishing, Foraging, etc. |
| F2 | Water / swim state hook | Free-form fishing + boats |
| F3 | NPC position override + AI suspend | Boat crew only |
| WSM | Slim World State Manager | Mutate · log · snapshot · cvars · projector |

## 1. Fishing & water (Survival)

- Fishing rods and spears
- Chance-based catch; skill raises success, lowers garbage loot (sandals, junk)
- Free-form cast at walk↔swim boundary (F2)
- Placeable docks + fish storage (static adjacency at place time)
- Crafting recipes using aquatic materials (FCS)
- Shoreline / water wildlife via existing spawn tables + logical predators later

## 2. Boats — Voyage

- Progressive: raft → dinghy → boat → ship (research/upgrade tree)
- Equippable item; swim visual/speed override (not true vehicles)
- Phase 1: solo only
- Phase 2: allied crew snapped to standing offsets + crossbow combat (F3)
- Player forward-facing harpoon (not full multi-turret ship combat)
- Clean board/unboard; no combat-while-swimming unlock — reframe as standing

## 3. Slavery Deep (player-as-slave focus)

- Real labor tasks while enslaved (mine, haul, cook, clean)
- Escapes beyond pure run: poison/drug, sabotage food, steal keys/uniforms, inform on others
- Reputation with slave faction → freedom or low-rank join
- Broken status (stat penalties + dialogue)
- Camp atmosphere; wire labor into town production where sensible
- **Not** full player-as-slaver empire in Phase 1

## 4. Small camps

- Light crafting + storage without creating a full outpost
- Light defensive post (harpoon/crossbow)
- Healing / recovery while camped
- Foraging markers (F1)
- Cosmetic squad idle chores (fire, sharpen)

## 5. Shadow (stealth / thievery / assassination)

- Dagger class: big bonus on stealth assassination
- Caltrops and similar tools
- Stealth archery (crossbow)
- Fencers in most taverns (buy stolen goods)
- Expand use of crouch/darkness within existing frameworks
- Ambient suspicion = low priority / cuttable

## 6. Towns & economy

- Near-player production loops → transfer to vendors → refresh inventories
- **Player-proximity guardrail** (ongoing cost; not global always-on)
- Job boards: modest pay, clear short goals (fish, clear threats, deliver, escort)
- Bounty boards: expand **existing** bounty system (regional, proof items)
- Optional visible hauling when player present (reuse haul jobs if possible)
- Gathering/crafting job entries (“bring 20 ore”)

## 7. Taverns

- Simple gambling (dice/cards) — KenshiLua dialogue example pattern
- Short mercenary / contract jobs
- Dynamic rumors + faction news from WSM events
- Faction-flavored atmospheres (HN / UC / Shek / …)
- Fencers + bounty boards
- Ambient eat/drink/social anims when present

## A. Alive Core (expansion — approved)

| Piece | Description |
|-------|-------------|
| Town schedules | Work / eat / sleep / tavern shifts (logical + near-player jobs) |
| Named regulars | A few faces per major town type |
| Light road traffic | Logical caravans; embody near player on roads |
| Rumor pipeline | EventHistory → tavern lines |
| Dormant production | Off-screen fraction scales abstract restock (StarFall idea) |

## Explicitly out of Phase 1–2

- Global always-on AI for every settlement
- Full multi-crew ship turret combat
- Player slaver empire economy
- Real sea physics / second navmesh
- Deep new combat types / formations
- Conquest / take-over-the-world politics
- Porting entire StarFall WSM surface

## Shipping

Standalone Workshop mod per system → bundle **Overhaul Suite 2.0** → later **3.0**.
