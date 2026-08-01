# Foundation spikes (do before large water/boat commitment)

## F1 — Dormant-stat skills

Kenshi stats are a fixed enum. Use unused/dark stats; rename for display; grant XP via recognized action or KenshiLib XP call.

**Exit criteria:** One skill (Fishing or Foraging) levels from a custom action and affects a number (catch chance).

## F2 — Water / swim state

Investigation order:

1. KenshiLua BindingReference / UnboundReference for swim/water/animation state  
2. KenshiLib character struct neighbors of known fields  
3. Only then memory scan enter/exit water  

**Exit criteria:** Reliable `isSwimming` (or equivalent) readable from plugin/Lua every tick.

**Fallback:** Dock/building-based fishing ships without free-form cast.

## F3 — Position override + AI suspend

Needed only for boat crew.

**Exit criteria:** Ally snapped to offset for 10s without fighting pathing; release restores normal AI.

## WSM v0.1

**Exit criteria:** Plugin loads, cvar off = no-op, menu opens, mutate economy once, snapshot round-trip in a test save note.
