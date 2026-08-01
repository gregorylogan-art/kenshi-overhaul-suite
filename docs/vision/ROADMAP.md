# Roadmap

## Phase 0 — Repo & spikes (now)

- [x] Vision / scope / architecture docs in this repo
- [ ] WSM v0.1 skeleton (mutate, snapshot stub, cvars, debug menu design)
- [ ] F2 discovery: is swim/water state bound in KenshiLua / KenshiLib?
- [ ] F1: pick dormant stat + one test skill (e.g. Fishing)

## Phase 1 — Shippable core (highest value, lowest risk)

Order optimized for iteration:

1. **WSM v0.1** live in RE_Kenshi plugin (no new world content)
2. **One town** production → vendor refresh (existing NPCs)
3. **Job boards** + bounty board expansion (dialogue + WSM offers)
4. **Slavery Deep** player-as-slave tasks + smarter escapes + rep
5. **Small camps**
6. **Shadow**: daggers + fencers
7. **Taverns**: gambling + contracts + rumors (basic)
8. **Fishing** once F2 is green (or dock-based fallback if F2 delayed)

## Phase 2 — Voyage & Alive

1. Progressive boats (solo equippable)
2. Crew standing-platform + crossbows (F3)
3. Alive Core: schedules, named regulars, light roads
4. Logical water wildlife + near-player presentation
5. Deeper slave camp atmosphere

## Phase 3 / 3.0 — Optional

- Hireable recurring traders
- Player shop stalls in owned buildings
- More stealth soft counters
- Extra boat tiers / limited sea content
- Richer faction news graph

## Definition of done (any system mod)

- [ ] Standalone load without the full suite (soft deps OK)
- [ ] Cvar or mod option default safe
- [ ] Save/load does not corrupt vanilla
- [ ] Player-proximity respected if simulated
- [ ] Documented in `docs/systems/`
- [ ] Basic smoke test notes in PR / commit message
