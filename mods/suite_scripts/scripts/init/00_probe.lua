-- ============================================================================
-- Kenshi Overhaul Suite -- FOUNDATION PROBE (spike 0)
--
-- Purpose: prove the Lua<->engine surface and dump exactly which globals and
-- water/swim APIs are reachable, so later systems are written against verified
-- facts instead of docs-guesses.
--
-- Loaded automatically: mods/<ActiveMod>/scripts/init/*.lua
-- Output goes to the KenshiLua Logger (Ctrl+Shift+L -> Logger tab).
-- Safe: read-only. Writes nothing to game state.
-- ============================================================================

local TAG = "[SUITE-PROBE] "

local function log(msg)
    print(TAG .. tostring(msg))
end

log("=== Foundation probe starting ===")

-- ---------------------------------------------------------------------------
-- 1. Enumerate global functions KenshiLua exposes (the real entry-point list)
-- ---------------------------------------------------------------------------
local globals = {}
for k, v in pairs(_G) do
    if type(v) == "function" then
        globals[#globals + 1] = k
    end
end
table.sort(globals)
log("global functions (" .. #globals .. "):")
-- chunk them so long lines don't get truncated in the log view
local line = "  "
for i = 1, #globals do
    line = line .. globals[i] .. "  "
    if #line > 90 or i == #globals then
        log(line)
        line = "  "
    end
end

-- ---------------------------------------------------------------------------
-- 2. GameWorld -- confirmed reachable (this is what printed as
--    "kenshilua.gameworld object" in the console)
-- ---------------------------------------------------------------------------
local okWorld, world = pcall(getGameWorld)
if okWorld and world then
    log("GameWorld: OK -> " .. tostring(world))
    local okPaused, paused = pcall(function() return world.paused end)
    if okPaused then log("  world.paused = " .. tostring(paused)) end
else
    log("GameWorld: FAILED (" .. tostring(world) .. ")")
end

-- ---------------------------------------------------------------------------
-- 3. Find a route to player characters.
--    getAllPlayerCharacters()/getAnyPlayerCharacter() live on PlayerInterface,
--    so we must locate the PlayerInterface singleton. Try the likely globals.
-- ---------------------------------------------------------------------------
local function tryGlobal(name)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn)
    if ok and res then return res end
    return nil
end

local player = tryGlobal("getPlayerInterface")
             or tryGlobal("getPlayer")
             or tryGlobal("getPlayerInstance")

if player then
    log("PlayerInterface: OK -> " .. tostring(player))
else
    log("PlayerInterface: not found via common globals -- see the global list above")
end

-- ---------------------------------------------------------------------------
-- 4. WATER / SWIM foundation (suite package F2).
--    Verified in BindingsReference:
--      Character:getWaterLevel()  -> integer
--      Character:getStats()       -> CharStats
--      CharStats.swimming         -> number (READ/WRITE)
--      CharStats:calculateSwimSpeed() / :calculateMaxSwimSpeed()
-- ---------------------------------------------------------------------------
local function probeCharacter(c, label)
    if not c then return end
    log("character [" .. label .. "] -> " .. tostring(c))

    local okW, water = pcall(function() return c:getWaterLevel() end)
    log("  getWaterLevel(): " .. (okW and tostring(water) or ("ERR " .. tostring(water))))

    local okS, stats = pcall(function() return c:getStats() end)
    if not okS or not stats then
        log("  getStats(): ERR " .. tostring(stats))
        return
    end
    log("  getStats(): OK -> " .. tostring(stats))

    local okSw, swimming = pcall(function() return stats.swimming end)
    log("  stats.swimming: " .. (okSw and tostring(swimming) or ("ERR " .. tostring(swimming))))

    local okSp, spd = pcall(function() return stats:calculateSwimSpeed() end)
    log("  calculateSwimSpeed(): " .. (okSp and tostring(spd) or ("ERR " .. tostring(spd))))

    local okMx, mx = pcall(function() return stats:calculateMaxSwimSpeed() end)
    log("  calculateMaxSwimSpeed(): " .. (okMx and tostring(mx) or ("ERR " .. tostring(mx))))
end

if player then
    local okAny, anyChar = pcall(function() return player:getAnyPlayerCharacter() end)
    if okAny and anyChar then
        probeCharacter(anyChar, "anyPlayerCharacter")
    else
        log("getAnyPlayerCharacter(): ERR " .. tostring(anyChar))
    end
end

-- ---------------------------------------------------------------------------
-- 5. Callback system -- the WSM heartbeat.
--    onCharsUpdate fires from GameWorld::charsUpdate, i.e. the sim tick.
--    Fires VERY often, so this handler self-unregisters after a few ticks;
--    it exists only to prove the event pipe is live.
-- ---------------------------------------------------------------------------
if type(registerHandler) == "function" then
    local ticks = 0
    local id
    id = registerHandler("onCharsUpdate", function()
        ticks = ticks + 1
        if ticks == 1 then
            log("onCharsUpdate: FIRING -- sim tick hook is live (WSM heartbeat available)")
        end
        if ticks >= 3 and type(unregisterHandler) == "function" then
            unregisterHandler(id)
            log("onCharsUpdate: probe handler unregistered after " .. ticks .. " ticks")
        end
    end)
    log("registerHandler: OK (onCharsUpdate id=" .. tostring(id) .. ")")
else
    log("registerHandler: NOT AVAILABLE as a global")
end

log("=== Foundation probe complete ===")
