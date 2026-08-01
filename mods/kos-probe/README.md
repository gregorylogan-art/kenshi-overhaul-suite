# kos-probe

Smoke-test mod for Kenshi Overhaul Suite foundations.

## Install

1. Copy this folder into your Kenshi `mods/` directory:
   `.../steamapps/common/Kenshi/mods/kos-probe/`
2. Enable **kos-probe** in the Kenshi launcher (and ensure RE_Kenshi + KenshiLua are active).
3. Load a save.
4. Press **Ctrl+Shift+L** for KenshiLua GUI / console.
5. Select a squad member, walk into the ocean/river.
6. Watch the logger for `water state changed -> DEEP_WATER` etc.
7. Or type: `kos_water()`

## What it proves (F2)

`Character:getWaterLevel()` returns a `WaterState` enum:

| Value | Name |
|------:|------|
| 0 | NO_WATER |
| 1 | VERY_SHALLOW_WATER |
| 2 | THIGH_DEEP_WATER |
| 3 | DEEP_WATER |

Free-form fishing / boat equip gates should use this (likely `>= THIGH_DEEP` or `== DEEP`).

## Remove

Disable the mod in the launcher and delete the folder when done.
