# World State Manager (WSM) — Kenshi port

## Role

In-process **control plane** loaded by RE_Kenshi. Not a second full game engine.

Inspired by StarFall’s `UWorldStateManager` patterns (mutate-only writes, event history, snapshot, cvars, dormant production) — **cherry-picked**, not ported wholesale.

## v0.1 surface (do this first)

### Lifecycle

- Init on plugin load / game start
- Shutdown clean
- Optional hotkey debug menu

### Categories (Phase 1 only)

| Category | Contents |
|----------|----------|
| Time | Game day / hour counter if needed |
| Economy | Vendor stocks, fish pressure, production queues |
| Settlements | Light: town id → boards, stock links |
| NpcRegistry | **Logical** NPCs only (id, role, home, schedule intent, flags) |
| Player | Slavery rep, notoriety hooks |
| WorldEvents | Rolling history + rumor seeds |

Add Magic/Ships/Tiles/etc. **never** unless a shipped system needs them.

### Contract

Every durable change:

1. **Apply** mutator to category  
2. **Log** one history row (category, source, day)  
3. **Trim** rolling window (e.g. 30 game-days)

```
MutateEconomy(fn) → RunMutateContract → CommitMutateWrite(Economy)
```

Bulk load: `ApplySnapshot` bypasses Mutate (no spam log).

### Reads

- Const accessors / ForEach helpers
- No silent writes on read paths

### Subscriptions (optional v0.1.1)

- Category dirty → UI / projector refresh after mutate window closes

### Projector (thin)

```
OnTick / OnPlayerEnterTown:
  for logical agents in radius:
    bind or update Kenshi Character (job, inventory, dialogue vars)
  for agents left radius:
    unbind / release body
```

### CVars

| CVar | Default | Meaning |
|------|---------|---------|
| `kos.wsm.enable` | 0 | Master switch |
| `kos.wsm.tickHz` | 10 | Logic tick |
| `kos.wsm.debugMenu` | 1 (dev) | Hotkey panel |
| `kos.economy.enable` | 0 | Production/vendors |
| `kos.alive.enable` | 0 | Schedules/roads |

## What we cherry-pick from StarFall WSM

**Keep ideas:** single write path, event history, snapshot, batch scopes later, living vs dormant producers, GUID batch rotation, write-authority observe mode, size watermarks later.

**Drop:** UObject/subsystem, full tile maps, hot-mirror SoA until proven need, StarFall-only domains (magic, salt, ice, pet bonds, …).

## Debug menu (minimum)

- Toggle systems  
- Dump economy stocks for current town  
- List logical NPCs in radius  
- Force day/hour advance  
- Show last N event history rows  

## Implementation home

- `src/wsm/` — C++ plugin sources (future)  
- Lua only for dialogue/event glue unless binding is easier for a spike  
