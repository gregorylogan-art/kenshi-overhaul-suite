-- ============================================================================
-- STAT PROBE: map stat IDs -> names, and find how to READ and GRANT skill XP.
--
-- Fishing should nudge Swimming, Labouring, Precision Shooting and Perception
-- (Greg's design). Stats are addressed by NUMBER, not name -- CharStats:getStat
-- and :getStatName both demanded a numeric argument in the sweep -- so first we
-- need the id->name map.
--
-- Also answers Greg's question: does Kenshi's game-speed control compress our
-- 5-second cast? Our timer counts onCharsUpdate ticks, so if that fires faster
-- under speed-up, casts finish sooner. Measures ticks/sec so it can be checked
-- at 1x vs 5x.
--
-- Run from the console:
--   dofile("mods/KenshiLua/scripts/init/18_stat_probe.lua")
-- ============================================================================

local TAG = "[STAT] "
local function log(m) print(TAG .. tostring(m)) end

local okC, char = pcall(function() return getSelectedCharacter() end)
if not okC or not char then log("select a character first") return end
local okS, stats = pcall(function() return char:getStats() end)
if not okS or not stats then log("no CharStats") return end

log("========== STAT MAP ==========")

-- 1. Walk stat ids and print name + current value. Kenshi has roughly 60-90
--    stats; 0..120 covers it with room to spare.
local named = 0
for id = 0, 120 do
    local okN, nm = pcall(function() return stats:getStatName(id) end)
    if okN and nm and nm ~= "" then
        local okV, val = pcall(function() return stats:getStat(id, false) end)
        if not okV then
            okV, val = pcall(function() return stats:getStat(id) end)
        end
        named = named + 1
        log(("id=%-3d %-28s value=%s"):format(id, tostring(nm), okV and tostring(val) or "?"))
    end
end
log(("---- %d named stats ----"):format(named))

-- 2. What XP-granting surface exists? (never called here -- just listed)
log("---- xp / stat methods on CharStats ----")
do
    local mt = getmetatable(stats)
    local idx = type(mt) == "table" and rawget(mt, "__index")
    local seen = {}
    for _, src in ipairs({ mt, type(idx) == "table" and idx or nil }) do
        if type(src) == "table" then
            pcall(function()
                for k, v in pairs(src) do
                    local key = tostring(k)
                    if not seen[key] and type(v) == "function"
                       and (key:lower():find("xp") or key:lower():find("stat")
                            or key:lower():find("skill") or key:lower():find("level")) then
                        seen[key] = true
                        log("   " .. key)
                    end
                end
            end)
        end
    end
end

-- 3. TICK RATE vs GAME SPEED. Run this, note ticks/sec, change Kenshi's speed,
--    run again and compare. If the rate changes, our cast timer is game-time
--    based (arguably correct) rather than wall-clock.
do
    local ticks, reported = 0, false
    local id
    id = registerHandler("onCharsUpdate", function()
        ticks = ticks + 1
        if ticks >= 300 and not reported then
            reported = true
            log(("TICK SAMPLE: %d onCharsUpdate calls elapsed -- compare this "):format(ticks))
            log("  interval at 1x vs speed-up to see if casts compress")
            if type(unregisterHandler) == "function" then pcall(unregisterHandler, id) end
        end
    end)
    log("tick sampler armed (300 ticks)")
end

log("========== END STAT MAP ==========")
