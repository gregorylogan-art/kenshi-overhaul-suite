# CLAUDE.md — Kenshi Overhaul Suite

> Read at the start of every session in this repo. **This project is unrelated to StarFall** (a separate Unreal project, still in active development). Never write StarFall notes here, and never write Kenshi notes into StarFall's `CLAUDE.md`.

## Identity

Single-player systems overhaul for **Kenshi** (Lo-Fi Games, OGRE engine, 2013). Not affiliated with Lo-Fi. Not Kenshi 2.

Goal: make Kenshi feel **alive and goal-rich for solo play without rewriting the game** — own the *logic* in a slim World State Manager (WSM) and project only what the player can see.

## The stack

| Layer | What | Where |
|---|---|---|
| **RE_Kenshi** v0.3.4 | Mod loader / plugin host | game root, `Plugin=RE_Kenshi` in `Plugins_x64.cfg` |
| **KenshiLib** | C++ access to engine internals | ships prebuilt with RE_Kenshi |
| **KenshiLua** v0.2.6 | Lua runtime exposing ~all of KenshiLib | `mods/KenshiLua/` |
| **KEP** v0.17.0 | Kenshi Extension Plugin | `mods/KenshiExtensionPlugin/` |
| **FCS** | Vanilla content editor (items/recipes/buildings/dialogue) | `forgotten construction set.exe` |

Game: `D:\SteamLibrary\steamapps\common\Kenshi` — Steam, **v1.0.68**. RE_Kenshi runs its own **1.0.65** copy at `RE_Kenshi\kenshi_x64.exe`; the main exe is untouched.

## Division of labor — internalize this

| Tool | Owns | ~Share |
|---|---|---|
| **FCS** | items, recipes, buildings, research, dialogue, factions, spawns, **animations** | ~60% |
| **KenshiLua** | behavior, hooks, overrides, logic, the WSM | ~30% |
| **C++ plugin** | only what Lua cannot reach (needs VS2019 + **VS2010 x64 toolset**) | ~10%, ideally 0 |

**Animation is NOT reachable from Lua** (`AnimationClass` is unbound). Animation belongs to FCS job/task definitions. Lua owns logic; FCS owns presentation.

## Non-negotiable rules

1. **Verify before building.** No system is written against a doc claim. `BindingsReference.md` is auto-generated from headers and has never been executed — treat it as a hypothesis. A capability must be ✅ in the spine table (`docs/architecture/SPINE.md`) before code depends on it.
2. **Never fight the engine.** If Kenshi can't do X, reframe the design (PROJECTOR rule 5). Do not burn weeks defeating a ban.
3. **Kenshi owns bodies; the WSM owns logic.** Our state is pure Lua, running in parallel. Never modify Kenshi source or collide with its internals. The Projector is the only bridge.
4. **Vertical slices only.** Ship one system complete and playable before starting the next. No broad shallow passes — that is how overhauls die.
5. **Contracts first, implementation later.** Lock the function signature early; let v0 internals be garbage. Refactors hurt when *interfaces* change, not internals.
6. **Read-only probing.** Anything that inspects the live game is pcall-wrapped, zero-arg, read-verb only, and never writes a field. See `tools/gen_probes.py` safety rules.
7. **Repo is the source of truth.** Scripts live in `mods/suite_scripts/` and are *deployed* into the game. Nothing exists only in the Kenshi folder — a Steam verify must never be able to eat work.
8. **Save policy (until 1.0): new game required; saves may break freely.** FCS bakes IDs into saves. Revisit at 1.0.
9. **`kos.*` naming** for cvars/config (Kenshi Overhaul Suite), never `sf.*`.
10. **GitHub issues are the north star**; milestone per phase.

## Ported from StarFall — patterns, never code

C++/UObject → Lua is a different runtime; port *ideas*. See `docs/references/STARFALL_WSM_CHERRYPICK.md`.

Take: mutate-only durable writes · event history + rolling trim · snapshot/restore · cvars default 0 · living-vs-dormant agents · `GUID % N` batch ticks · proximity guardrail.

**Bugs learned there — do not re-earn them.** Both are tick-catch-up bugs, and the WSM will have a tick catch-up:
- **Wrapping-counter freeze:** `if (now <= lastProcessed) return;` against a counter that *wraps* silently kills a system forever. Use a monotonic counter.
- **Watermark advanced outside the ready-gate:** never mark work processed when it did not run (e.g. content not loaded yet) — those units are lost forever.

## Layout

```
docs/            vision, architecture (WSM/PROJECTOR/GUARDRAILS), systems/*.md, SETUP-LOCAL.md
mods/suite_scripts/   Lua source of truth -> deployed to game
tools/           gen_probes.py (manifest generator) and future tooling
third_party/     cloned toolchain (RE_Kenshi, KenshiLib, KenshiLua, KEP, examples) - do not edit
downloads/       prebuilt releases + config backups
```

## Environment gotchas

- Scripts auto-load from `mods/<ActiveMod>/scripts/init/*.lua`. Other dirs under `scripts/` do **not** auto-load.
- **`data/mods.cfg` IS the Mods tab** — one `.mod` filename per line. Editing it enables/disables mods; no launcher UI needed.
- In-game GUI: **`Ctrl+Shift+L`** (Script Manager / Editor / Console / Logger). `start_minimized=true` in `mods/KenshiLua/plugin/config.ini`.
- ⚠️ **Steam "Verify integrity of game files" reverts `Plugins_x64.cfg`**, silently disabling RE_Kenshi. Backups live in `downloads/`.
- All prebuilt binaries come from **GitHub Releases**; Nexus is not required (FCS Extended is the one exception, and it is optional).

## Collaboration

Greg's background is **Unreal only** — he has never modded Kenshi at the code level. Explain in plain English, analogize to Unreal where it genuinely helps, and never assume Kenshi conventions are known. Flag scope risk early and honestly; he would rather hear "this is hard and here's why" than get an optimistic estimate.
