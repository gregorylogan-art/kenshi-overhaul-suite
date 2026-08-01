# Foundation spikes (do before large water/boat commitment)

## F1 — Dormant-stat skills

Kenshi stats are a fixed enum. Use unused/dark stats; rename for display; grant XP via recognized action or KenshiLib XP call / `onCharStatsXpStatEvent`.

**Exit criteria:** One skill (Fishing or Foraging) levels from a custom action and affects a number (catch chance).

## F2 — Water / swim state ✅ API FOUND (needs in-game verify)

### Discovery (2026-08-01, KenshiLib + KenshiLua)

`Character::getWaterLevel()` is mapped and **bound to Lua**:

```lua
local level = character:getWaterLevel()  -- integer WaterState::Enum
```

From `KenshiLib/Include/kenshi/Character.h`:

```cpp
class WaterState {
  enum Enum {
    NO_WATER,
    VERY_SHALLOW_WATER,
    THIGH_DEEP_WATER,
    DEEP_WATER
  };
};
WaterState::Enum getWaterLevel(); // public RVA = 0x5C7850
```

Lua binding: `CharacterBinding::getWaterLevel` → `obj:getWaterLevel()`.

### Investigation result

| Step | Result |
|------|--------|
| 1. BindingReference | `getWaterLevel` listed |
| 2. KenshiLib Character.h | `WaterState` enum present |
| 3. Memory scan | **Not needed** for v1 |

### In-game verify

Use mod folder `mods/kos-probe` (this repo) — see its README.

**Exit criteria:** Log shows state change land → water → land on a selected character.

**Fallback (if broken on your build):** Dock/building-based fishing only.

## F3 — Position override + AI suspend

Needed only for boat crew. `CharMovement` has `setPositionAndTeleport`, `halt`, etc. — spike after F2 verified.

**Exit criteria:** Ally snapped to offset for 10s without fighting pathing; release restores normal AI.

## WSM v0.1

**Exit criteria:** Plugin or Lua layer loads, cvar/flag off = no-op, menu or log dump, mutate economy once, snapshot round-trip notes.
