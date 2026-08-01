# StarFall WSM → Kenshi cherry-pick notes

Source: user-provided `WorldStateManager.cpp` (StarFall / Unreal).

## Port these patterns

| Pattern | Kenshi use |
|---------|------------|
| Mutate-only durable writes | All economy/NPC logical changes |
| EventHistory + rolling trim | Rumors, debug, quests |
| CaptureSnapshot / ApplySnapshot | Save beside Kenshi |
| Batch mutation scope (later) | Town production ticks |
| CVars default 0 | Every package |
| Living vs dormant agents | Off-screen production fraction |
| GUID % N batch ticks | Hourly NPC logic |
| Category change subscriptions | Vendor UI refresh |
| Write-authority observe mode | Catch illegal writers in dev |

## Do not port first

- UGameInstanceSubsystem / UObject  
- Full Environment tile maps at StarFall scale  
- Hot mirror SoA + aggregates until profiling demands  
- Magic, ships-as-StarFall, salt/ice, pet bonds, war arc, fog of war  
- Shipping-specific witness journal complexity (optional later)

## Naming

Use `kos.*` cvars (Kenshi Overhaul Suite), not `sf.wsm.*`.
