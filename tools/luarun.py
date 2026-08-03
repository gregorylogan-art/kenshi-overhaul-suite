#!/usr/bin/env python3
"""luarun.py -- run suite Lua headlessly, with no Kenshi and no game running.

WHY THIS EXISTS
Every check so far has been "lint says OK" plus a live play session. Lint proves
syntax, not behaviour, and a play session costs Greg real time and can only be
run when he is awake. Whole classes of bug in this project were pure logic and
needed no game at all to catch:

  * FISH_PREFERENCE used above its own declaration -> nil -> threw on every cast
  * a Lua `and` truncating multiple returns, so every cast hung on "already casting"
  * a junk band falling through to fish, turning a shipped 5/80/15 into 5/95
  * an odds model that was never called from the live path

All four are reproducible in a bare interpreter.

Kenshi ships lua51.dll but no lua.exe, so this drives that DLL directly through
ctypes -- the SAME LuaJIT-compatible 5.1 runtime the game uses, rather than a
different Lua that might disagree about semantics.

Engine functions (getSelectedCharacter, getForgottenGUI, ...) do not exist here.
Modules that only touch Lua state -- Items, Cooking odds, WSM -- run fully. That
is deliberate: those are exactly the modules where a logic bug is invisible
until it corrupts something.

Usage:
    python tools/luarun.py --selftest              # run every module selftest
    python tools/luarun.py --eval "print(1+1)"
    python tools/luarun.py --file path/to.lua
"""
from __future__ import annotations

import argparse
import ctypes
import sys
from pathlib import Path

DLL = Path(r"D:\SteamLibrary\steamapps\common\Kenshi\mods\KenshiLua\lua51.dll")
INIT = Path(r"D:\kenshi-overhaul-suite\mods\suite_scripts\scripts\init")

LUA_GLOBALSINDEX = -10002
LUA_MULTRET = -1


class Lua:
    def __init__(self, dll_path: Path = DLL):
        if not dll_path.is_file():
            raise FileNotFoundError(f"lua51.dll not found at {dll_path}")
        self.lib = ctypes.CDLL(str(dll_path))
        L = self.lib

        L.luaL_newstate.restype = ctypes.c_void_p
        L.luaL_openlibs.argtypes = [ctypes.c_void_p]
        L.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        L.luaL_loadstring.restype = ctypes.c_int
        L.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        L.lua_pcall.restype = ctypes.c_int
        L.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        L.lua_tolstring.restype = ctypes.c_char_p
        L.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
        L.lua_close.argtypes = [ctypes.c_void_p]

        self.S = ctypes.c_void_p(L.luaL_newstate())
        if not self.S:
            raise RuntimeError("luaL_newstate returned NULL")
        L.luaL_openlibs(self.S)

    def run(self, code: str, chunkname: str = "chunk") -> tuple[bool, str]:
        """Load and call `code`. Returns (ok, error_message)."""
        rc = self.lib.luaL_loadstring(self.S, code.encode("utf-8"))
        if rc != 0:
            return False, self._pop_error()
        rc = self.lib.lua_pcall(self.S, 0, LUA_MULTRET, 0)
        if rc != 0:
            return False, self._pop_error()
        return True, ""

    def _pop_error(self) -> str:
        msg = self.lib.lua_tolstring(self.S, -1, None)
        self.lib.lua_settop(self.S, -2)
        return (msg or b"unknown error").decode("utf-8", "replace")

    def close(self):
        if self.S:
            self.lib.lua_close(self.S)
            self.S = None


# KenshiLua's sandbox is emulated ONLY to the extent that matters here: scripts
# read through to _G. The private-write behaviour is deliberately NOT emulated,
# because every suite module already publishes through _G explicitly and a
# faithful sandbox would hide regressions in that publishing rather than expose
# them.
PRELUDE = r"""
-- Engine surface is absent by design. A module that calls into it while merely
-- LOADING is a bug worth failing on here, so these are not stubbed out.
_G.__HEADLESS = true
"""


def load_modules(lua: Lua, names: list[str]) -> list[str]:
    problems = []
    for name in names:
        path = INIT / name
        if not path.is_file():
            problems.append(f"{name}: not found")
            continue
        code = path.read_text(encoding="utf-8", errors="replace")
        ok, err = lua.run(code, name)
        if not ok:
            problems.append(f"{name}: {err}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description="headless Lua runner for the suite")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--tests", action="store_true")
    ap.add_argument("--eval", default="")
    ap.add_argument("--file", default="")
    ap.add_argument("--modules", default="15_items.lua,24_cooking.lua")
    args = ap.parse_args()

    try:
        lua = Lua()
    except Exception as exc:  # noqa: BLE001
        print(f"cannot start lua: {exc}", file=sys.stderr)
        return 2

    lua.run(PRELUDE, "prelude")

    if args.eval:
        ok, err = lua.run(args.eval, "eval")
        if not ok:
            print(f"ERROR: {err}", file=sys.stderr)
            return 1
        return 0

    if args.file:
        code = Path(args.file).read_text(encoding="utf-8", errors="replace")
        ok, err = lua.run(code, args.file)
        if not ok:
            print(f"ERROR: {err}", file=sys.stderr)
            return 1
        return 0

    if args.tests:
        names = [n.strip() for n in args.modules.split(",") if n.strip()]
        problems = load_modules(lua, names)
        if problems:
            print("MODULE LOAD FAILURES:")
            for p in problems:
                print("  " + p)
            return 1
        tests = sorted((Path(__file__).parent.parent / "tests").glob("*.lua"))
        if not tests:
            print("no test files found", file=sys.stderr)
            return 1
        bad = 0
        for t in tests:
            print(f"=== {t.name} ===")
            ok, err = lua.run(t.read_text(encoding="utf-8", errors="replace"), t.name)
            if not ok:
                print(f"  {err}", file=sys.stderr)
                bad += 1
        return 1 if bad else 0

    if args.selftest:
        names = [n.strip() for n in args.modules.split(",") if n.strip()]
        problems = load_modules(lua, names)
        if problems:
            print("MODULE LOAD FAILURES:")
            for p in problems:
                print("  " + p)
            return 1

        # Call whatever selftests exist; a module without one is reported, not
        # silently skipped -- an unreported gap reads as a pass.
        ok, err = lua.run(
            r"""
            local ran, failed = 0, 0
            for _, name in ipairs({ "Items", "Cooking", "WSM" }) do
                local mod = _G[name]
                if mod and type(mod.selftest) == "function" then
                    ran = ran + 1
                    print("=== " .. name .. ".selftest() ===")
                    local ok, res = pcall(mod.selftest)
                    if not ok then
                        failed = failed + 1
                        print("  ERROR: " .. tostring(res))
                    elseif res == false then
                        failed = failed + 1
                    end
                else
                    print("=== " .. name .. ": no selftest (skipped) ===")
                end
            end
            print(("=== %d selftest(s) ran, %d failed ==="):format(ran, failed))
            if failed > 0 then error("selftests failed", 0) end
            """,
            "selftest",
        )
        if not ok:
            print(f"FAILED: {err}", file=sys.stderr)
            return 1
        return 0

    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
