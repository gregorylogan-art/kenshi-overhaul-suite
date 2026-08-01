# Kenshi Overhaul Suite

**Single-player systems overhaul for [Kenshi](https://lofigames.com/)** — fishing & water, progressive boats, deeper slavery, small camps, stealth tools, living towns/economy, and richer taverns.

> **Not affiliated with Lo-Fi Games.** This is a community passion project.  
> **Not official Kenshi 2** (Lo-Fi’s sequel is a separate UE5 project).  
> Repo name deliberately avoids `kenshi-2` / bare `kenshi` branding.

| | |
|---|---|
| **Author** | [gregorylogan-art](https://github.com/gregorylogan-art) |
| **Status** | Design + foundation (docs first; implementation next) |
| **Toolchain** | FCS · [RE_Kenshi](https://github.com/BFrizzleFoShizzle/RE_Kenshi) · [KenshiLib](https://github.com/BFrizzleFoShizzle/KenshiLib) · [KenshiLua](https://github.com/Genpretz/KenshiLua) · optional KEP / Re_Dev |
| **Architecture** | Slim in-process **World State Manager (WSM)** = control plane; Kenshi = bodies, pathing, combat near the player |

---

## Vision (one sentence)

Make Kenshi feel **alive and goal-rich** for solo play — without rewriting the game — by owning *logic* in a WSM and projecting only what the player can see.

Full write-up: [docs/vision/VISION.md](docs/vision/VISION.md)

---

## Systems (canonical list)

| # | Package | Summary |
|---|---------|---------|
| 0 | **Foundation** | F1 dormant-stat skills · F2 water/swim state · F3 boat crew hooks · slim WSM |
| 1 | **Fishing & water** | Rods/spears · skill + garbage loot · free-form cast · docks · aquatic recipes |
| 2 | **Boats (Voyage)** | Raft → ship equippables · crew crossbows · player forward harpoon |
| 3 | **Slavery Deep** | Player-as-slave labor · smarter escapes · rep path · Broken status |
| 4 | **Small camps** | Light craft/storage · defense · heal · no full outpost |
| 5 | **Shadow** | Daggers · fencers · caltrops · stealth archery |
| 6 | **Towns & economy** | Near-player production → vendors · job boards · bounties |
| 7 | **Taverns** | Gambling · contracts · rumors · faction flavor |
| A+ | **Alive Core** | Schedules · named regulars · light road traffic · event→rumor pipeline |

Details: [docs/vision/SCOPE.md](docs/vision/SCOPE.md) · Phasing: [docs/vision/ROADMAP.md](docs/vision/ROADMAP.md)

---

## Architecture at a glance

```
Kenshi process
├── Vanilla loop (render, navmesh, combat, AI packages)
└── RE_Kenshi plugin
    ├── World State Manager (our truth: economy, logical NPCs, jobs, slavery rep…)
    ├── Tick 10–20 Hz, player-proximity / ~viewport+100m bodies only
    ├── Projector → Character jobs, inventory, dialogue vars, anim overrides
    └── Hotkey menu (cvar on/off + debug dumps)
```

- **Logical NPCs** always live in WSM.  
- **Meshes** only when near the player.  
- **Lua/FCS** = glue (dialogue, research, buildings).  
- **C++ WSM** = authority for complex systems.

See [docs/architecture/WSM.md](docs/architecture/WSM.md) and [docs/architecture/GUARDRAILS.md](docs/architecture/GUARDRAILS.md).

---

## Repo layout

```
docs/
  vision/          VISION, SCOPE, ROADMAP, PRINCIPLES
  architecture/    WSM, projector, toolchain, guardrails
  systems/         One brief per system (fishing, boats, …)
  ideas/           Parking lot / 3.0 ideas / open questions
  references/      External links, StarFall WSM cherry-pick notes
mods/              Future standalone Workshop mod folders
src/wsm/           Future C++/Lua WSM skeleton
scripts/           Helpers
```

---

## Shipping model

1. Each system ships as its **own Steam Workshop / Nexus mod** when ready.  
2. Bundle complete systems into **Overhaul Suite 2.0**.  
3. Later wave = **3.0** (Alive expansions, more voyage, etc.).

Features behind **cvars default OFF** until stable.

---

## Working in this repo

- Design changes → edit `docs/` and open an issue if it changes scope.  
- Code → `src/` and `mods/` with small PRs / commits per system.  
- Never name releases “Kenshi 2.0”.  
- Passion project: favor **simple, shippable, player-prox** over global simulation.

---

## License

Mod content intended for Kenshi community distribution.  
Kenshi © Lo-Fi Games. This project is unofficial and non-commercial unless stated otherwise.

See [LICENSE](LICENSE).
