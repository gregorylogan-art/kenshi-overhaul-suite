# Local Modding Setup — this PC

Machine-specific setup notes. Generated 2026-08-01.

| | |
|---|---|
| **Suite repo** | `D:\kenshi-overhaul-suite` (separate from StarFall) |
| **Toolchain** | `D:\kenshi-overhaul-suite\third_party\` (5 repos, source) |
| **Downloads** | `D:\kenshi-overhaul-suite\downloads\` (prebuilt releases) |
| **Kenshi install** | `D:\SteamLibrary\steamapps\common\Kenshi` |
| **Kenshi version** | **1.0.68** (Steam) |
| **Mods dir** | `D:\SteamLibrary\steamapps\common\Kenshi\mods\` |

---

## What is already done ✅

**Toolchain source cloned** (`third_party/`, via `scripts/clone-toolchain.sh`):
`RE_Kenshi` · `KenshiLib` · `KenshiLib_Examples` · `KenshiLua` · `KenshiExtensionPlugin`

**Prebuilt releases downloaded** (`downloads/`) — all from official GitHub Releases, no Nexus needed:

| File | Version | Purpose |
|---|---|---|
| `RE_Kenshi_v0.3.4.zip` | v0.3.4 | **Installer** (packaged) — the one to run |
| `RE_Kenshi_v0.3.4_loose.zip` | v0.3.4 | Loose DLLs, for reference/manual inspection |
| `KenshiLua.v0.2.6-alpha.zip` | v0.2.6 | Lua runtime mod |
| `KenshiExtensionPlugin_v0.17.0.zip` | v0.17.0 | KEP |
| `kep-devtools_v0.17.0.zip` | v0.17.0 | KEP dev tools |
| `KenshiLib_v0.4.0.zip` | v0.4.0 | KenshiLib SDK (C++ headers/libs) |

**Mods installed** into `Kenshi\mods\`:
- `KenshiLua/` (has `KenshiLua.mod`, `lua51.dll`, `gui/`, `docs/`)
- `KenshiExtensionPlugin/` (has `KenshiExtensionPlugin.mod`, `kep-core-x64.dll`)

**Backup taken**: `downloads/Plugins_x64.cfg.BACKUP-<date>` (pre-modification copy of the game's plugin config).

---

## What YOU must do — 3 steps ⚠️

These are the only remaining steps. They need a human because they modify the game install and require GUI/game interaction.

### 1. Run the RE_Kenshi installer

```
D:\kenshi-overhaul-suite\downloads\extracted\RE_Kenshi_v0.3.4.exe
```
(or extract `RE_Kenshi_v0.3.4.zip` and run the `.exe` inside)

- Point it at `D:\SteamLibrary\steamapps\common\Kenshi`
- **Expect a version downgrade.** Per the official Readme: RE_Kenshi targets **1.0.65**, and you are on **1.0.68**, so *"a downgraded version of Kenshi will automatically be created during installation."* This is normal, automatic, and reversible (re-run the installer → Uninstall). Needs ~200 MB.
- The installer edits `Plugins_x64.cfg` for you (adds `Plugin=RE_Kenshi`). Do **not** hand-edit it — a manual DLL copy is the wrong path on 1.0.68.
- To run vanilla 1.0.68 later, add launch flag `--norekenshi`.

### 2. Launch Kenshi and enable the mods

Launcher → **Mods** tab → tick **KenshiLua** and **KenshiExtensionPlugin**.

### 3. Verify

RE_Kenshi settings: **OPTIONS → MODS → RE_KENSHI SETTINGS**.
KenshiLua adds an in-game GUI: Script Manager, **Script Editor**, **Console**, Logger.
Type something in the KenshiLua console to confirm the Lua runtime is live.

---

## Path A — Lua modding (recommended, no compiler) ⭐

**KenshiLua removes the entire C++ toolchain problem.** It embeds a Lua runtime and exposes nearly all of KenshiLib 0.3.0 to Lua, editable **in-game** with live iteration.

**No VS2010, no Boost 1.60, no DirectX June 2010 SDK required.**

Reference docs (also copied into the installed mod at `mods\KenshiLua\docs\`):
- `third_party/KenshiLua/docs/BindingsReference.md` — everything callable from Lua (776 KB)
- `third_party/KenshiLua/docs/CallbacksReference.md` — gameplay events you can hook (41 KB)
- `third_party/KenshiLua/docs/UnboundRefrence.md` — KenshiLib parts *not* yet exposed (176 KB)

Example:
```lua
local world = getGameWorld()
world:userPause(true)
```

Scripts load from a mod folder at runtime, or execute from FCS-Extended dialogues.

## Path B — C++ plugins (only if Lua can't reach it)

Needed **only** for native plugins (`KenshiLib_Examples`).

Requires **Visual Studio 2019+ AND the Visual C++ 2010 x64 compiler toolset** — plugins *must* be built with the VS2010 compiler. This is the painful path; check `UnboundRefrence.md` first to confirm Lua really can't do what you need.

First target: `third_party/KenshiLib_Examples/HelloWorld/` — prints "Hello World!" to RE_Kenshi's debug log.
Build → copy `HelloWorld/` to `Kenshi/mods/HelloWorld/` → copy `x64/Release/HelloWorld.dll` in beside it → enable in the Mods tab.

Other examples worth reading: `KillButton` (MyGUI UI), `Dialogue` (custom dialogue conditions/effects), `WorldStates` (persistent state + custom GameData — closest to the suite's WSM design), `PluginExport`/`PluginImport` (plugin-to-plugin APIs).

## Not automated

- **FCS Extended** (optional, for `Dialogue`/`WorldStates` examples) — Nexus-only, manual download: https://www.nexusmods.com/kenshi/mods/1825
- **FCS** (Forgotten Construction Set) ships with the game: `Kenshi\forgotten construction set.exe`

## Uninstall / rollback

- RE_Kenshi: re-run installer → **Uninstall**; or remove `Plugin=RE_Kenshi` from `Plugins_x64.cfg`.
- Mods: delete `Kenshi\mods\KenshiLua` and `Kenshi\mods\KenshiExtensionPlugin`.
- Plugin config: restore `downloads/Plugins_x64.cfg.BACKUP-<date>`.
