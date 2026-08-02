-- ============================================================================
-- SANDBOX ESCAPE TEST
--
-- KenshiLua gives every script its own environment (ScriptLoader.cpp,
-- createSandboxEnv):
--     env = {}                       -- fresh table per script
--     setmetatable(env, { __index = _G })
--     lua_setfenv(chunk, env)
--
-- So READS fall through to the real global table, but WRITES land in the
-- script's private table -- there is no __newindex. That is why
-- `Fishing.grantXp` was nil across files and XP silently never fired.
--
-- HYPOTHESIS: because reads fall through, `_G` itself resolves to the REAL
-- global table, so `_G.NAME = value` should write somewhere every script and
-- the console can see.
--
-- This writes both ways. Then check from the CONSOLE (a different environment):
--     print(KOS_SANDBOX_LOCAL, _G.KOS_SANDBOX_SHARED)
--   nil / table  -> hypothesis CONFIRMED: _G.X is the shared channel
--   both nil     -> even _G is per-script; we need another route
--   both present -> console shares this env; test is inconclusive, use 2 files
--
--   dofile("mods/KenshiLua/scripts/26_sandbox_test.lua")
-- ============================================================================

local TAG = "[SANDBOX] "
local function log(m) print(TAG .. tostring(m)) end

log("=== sandbox escape test ===")

-- 1. the ordinary (broken) way -- writes into this script's private env
KOS_SANDBOX_LOCAL = { note = "written as a bare global" }
log("wrote bare global   KOS_SANDBOX_LOCAL")

-- 2. the candidate escape -- writes into the REAL global table
local okG, G = pcall(function() return _G end)
if not okG or type(G) ~= "table" then
    log("FAIL: _G is not reachable (type=" .. type(G) .. ")")
    return
end
log("_G is reachable, type=" .. type(G))

G.KOS_SANDBOX_SHARED = { note = "written through _G" }
log("wrote               _G.KOS_SANDBOX_SHARED")

-- 3. is our env genuinely separate from _G?
local okEnv, env = pcall(getfenv, 1)
if okEnv and type(env) == "table" then
    log("getfenv(1) is a table; env == _G ? " .. tostring(rawequal(env, G)))
    local mt = getmetatable(env)
    log("env has metatable  : " .. tostring(mt ~= nil))
    if type(mt) == "table" then
        log("metatable.__index == _G ? " .. tostring(rawequal(rawget(mt, "__index"), G)))
    end
end

-- 4. can we see something written by a DIFFERENT script? 05_wsm defines WSM.
log("WSM visible here?    " .. tostring(rawget(G, "WSM") ~= nil) .. "  (via _G)")
log("WSM as bare global?  " .. tostring(WSM ~= nil) .. "  (falls through __index)")

log("")
log("NOW RUN THIS IN THE CONSOLE:")
log("  print(KOS_SANDBOX_LOCAL, _G.KOS_SANDBOX_SHARED)")
log("  nil then table  -> _G.X is the shared channel (what we want)")
log("=== end ===")
