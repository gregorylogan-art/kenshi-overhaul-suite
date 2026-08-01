# Toolchain

Kenshi runs on OGRE with no official scripting API. Everything beyond FCS is community reverse engineering.

| Component | Role | Links |
|-----------|------|--------|
| **FCS** | Data: items, buildings, dialogue, research, AI packages | Bundled with game |
| **RE_Kenshi** | DLL injection, hooks, plugin load | Nexus 847 · `BFrizzleFoShizzle/RE_Kenshi` |
| **KenshiLib** | Mapped internals (characters, items, stats, …) | Bundled / `BFrizzleFoShizzle/KenshiLib` · Examples repo |
| **KenshiLua** | LuaJIT bindings + dialogue “run script” + events | GitHub-only `Genpretz/KenshiLua` |
| **FCS Extended** | Dialogue nodes can run Lua | With KenshiLua |
| **KEP** | Bugfix / feature layer | `Lucius64/KenshiExtensionPlugin` |
| **Re_Dev** | In-game F12-style tools | Nexus 2002 |

## Before writing custom logic

1. Read KenshiLua `BindingReference.md` and `UnboundReference.md`.
2. Check KenshiLib examples for the same problem class.
3. Prefer FCS data if it already expresses the rule.

## Build notes (C++ plugins)

- VS 2010-compatible toolset for matching ABI (see RE_Kenshi / KenshiLib docs).
- Prefer precompiled RE_Kenshi + KenshiLib for plugin work when possible.
- Game updates can break offsets until community catches up.

## Risk

Community-maintained, version-locked. Design for “feature may pause after a patch.”
