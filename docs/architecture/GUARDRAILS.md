# Architecture guardrails

## Control plane vs presentation

| Layer | Owns | Must not |
|-------|------|----------|
| **WSM** | Truth for our systems (stocks, logical NPCs, jobs, rep, events) | Assume global pathing |
| **Projector** | Near-player Character bind, jobs, inventory, dialogue, anim overrides | Become a second physics engine |
| **Kenshi** | Mesh, navmesh, combat, vanilla AI, swimming anims | Be rewritten |
| **Lua/FCS** | Hooks, buildings, research, dialogue text | Hold complex multi-system state long-term |

## Viewport rule

- **Logical** agents: anywhere (cheap tables).
- **Embodied** agents: player viewport **or ~100 m beyond**.
- When far: despawn/unbind body; keep logical record; optional dormant production fraction.

## Tick budget

- WSM tick target: **10–20 Hz** or game-hour cadence for bulk systems.
- NPC batching (e.g. GUID % 4) for hourly work.
- No full roster walk every frame.

## Save/load

- WSM snapshot lives **with or beside** Kenshi save.
- Load must not double-log history (bypass Mutate on ApplySnapshot).
- Never corrupt vanilla if mod removed (graceful missing state).

## Feature flags

```
kos.wsm.enable=0
kos.economy.enable=0
kos.alive.schedules=0
kos.voyage.crew=0
...
```

Default **0** until soak-tested.
