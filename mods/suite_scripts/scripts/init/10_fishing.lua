-- ============================================================================
-- Kenshi Overhaul Suite -- FISHING v0
--
-- The first complete player-facing loop:
--     stand/swim in water  ->  press key  ->  timer  ->  caught a fish
--
-- CONTRACT (locked now, implementation is disposable):
--     Fishing.canFish(character)        -> boolean, reason
--     Fishing.tryCatch(character)       -> caught:boolean, itemId:string, isGarbage:boolean
--     Fishing.state                     -> per-character session table
-- v0 rolls a coin. v5 will roll skill curves, loot tables and regional fish
-- pressure behind the SAME signatures, so callers never change. Refactors hurt
-- when interfaces move, not when internals do.
--
-- BUILT ONLY ON VERIFIED CAPABILITIES (probe run 2026-08-01):
--     getSelectedCharacter()          -> Character          VERIFIED
--     CharStats.swimming              = 1 while swimming    VERIFIED
--     Character:getWaterLevel()       -> integer            VERIFIED
--     Character:getName()             -> string             VERIFIED
--     character:getStats()/:getInventory()                  VERIFIED
--     registerHandler("onCharsUpdate")                      VERIFIED
-- NOT used, because the probe proved they do NOT exist:
--     Character:getPos(), Character:getHealth(),
--     CharStats:calculateMaxSwimSpeed()
--
-- ANIMATION: none. AnimationClass is unbound in Lua -- animation belongs to an
-- FCS job definition (v2). v0 gives feedback through the log instead.
-- ITEM GRANT: route unknown until the sweep confirms it. v0 banks catches in
-- suite state and reports which grant route works, so v0.1 can mint real items.
-- ============================================================================

local TAG = "[FISH] "
local function log(m) print(TAG .. tostring(m)) end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local CFG = {
    -- 33 = F was CONFIRMED working, but F is bound to centre-on-character in
    -- vanilla Kenshi, so it double-fires. 34 = G, which vanilla appears to
    -- leave free. Change here if it collides; the keycode logger finds codes.
    fishKey     = 34,    -- G
    castSeconds = 3.0,
    baseChance  = 0.25,
    garbageOdds = 0.40,
    logKeycodes = false,

    -- DESIGN (Greg, 2026-08-01): fish while WADING, not while SWIMMING.
    -- Swimming locks the character's animation state, so no fishing animation
    -- can ever play there -- and the suite design always said "free-form cast at
    -- the walk<->swim boundary". Wading = in water, still standing, animation free.
    --
    -- MEASURED depth gradient (live survey, deep shelf -> shore -> land -> hill):
    --     waterLevel 3  swimming 1.05 .. 8.77   deep / swimming
    --     waterLevel 2  swimming 1              shallow / wading
    --     waterLevel 0  swimming 12.91          ON LAND
    --
    -- CRITICAL: `swimming` is NOT a boolean and NOT depth -- it is an accumulator
    -- that LAGS. It read 12.91 while standing on dry land. Gating on it would
    -- block fishing everywhere. `waterLevel` is the trustworthy depth signal, so
    -- the rule is a waterLevel BAND.
    minWaterLevel = 1,   -- below this = dry land, nothing to fish
    maxWaterLevel = 2,   -- above this = too deep, swim animation locks the body

    -- Keep dumping the full state on every press until the band is confirmed
    -- across more shorelines. Cheap, and it is how both prior rules got fixed.
    surveyMode  = true,
}

-- ---------------------------------------------------------------------------
-- Suite state (proto-WSM). Durable truth lives here, not in the engine.
-- ---------------------------------------------------------------------------
Fishing = Fishing or {}
Fishing.state = Fishing.state or {}      -- [charName] = { casting, elapsed, caught, garbage }

local function stateFor(name)
    local s = Fishing.state[name]
    if not s then
        s = { casting = false, elapsed = 0, caught = 0, garbage = 0 }
        Fishing.state[name] = s
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Deterministic-ish roll. Lua's math.random is fine for v0; a seeded stream
-- comes with the WSM so catches are replayable.
-- ---------------------------------------------------------------------------
local function roll() return math.random() end

-- ---------------------------------------------------------------------------
-- CONTRACT: canFish
-- Water test uses `swimming`, NOT getWaterLevel -- the probe caught them
-- disagreeing (swimming=1 while getWaterLevel=0), so `swimming` is the
-- trustworthy signal.
-- ---------------------------------------------------------------------------
-- Read every water-ish signal we have verified, so thresholds come from
-- measurement instead of guesswork.
function Fishing.readWaterState(character)
    local st = {}
    local function grab(key, fn)
        local ok, v = pcall(fn)
        st[key] = ok and v or nil
        return st[key]
    end
    local ok, stats = pcall(function() return character:getStats() end)
    if ok and stats then
        grab("swimming", function() return stats.swimming end)
        grab("swimSpeed", function() return stats:calculateSwimSpeed() end)
    end
    grab("waterLevel",    function() return character:getWaterLevel() end)
    grab("terrainHeight", function() return character:getTerrainHeightPosition() end)
    grab("isOnARoof",     function() return character:isOnARoof() end)
    return st
end

local function describe(st)
    return ("swimming=%s waterLevel=%s swimSpeed=%s terrainH=%s")
        :format(tostring(st.swimming), tostring(st.waterLevel),
                tostring(st.swimSpeed), tostring(st.terrainHeight))
end

function Fishing.canFish(character)
    if not character then return false, "no character" end
    local st = Fishing.readWaterState(character)
    local desc = describe(st)

    -- Gate on waterLevel ONLY. `swimming` is deliberately ignored for the
    -- decision (it lagged at 12.91 on dry land); it is still logged because it
    -- may become useful once we understand what it accumulates.
    local water = (type(st.waterLevel) == "number") and st.waterLevel or 0

    if water < CFG.minWaterLevel then
        return false, "on land -- wade into the shallows | " .. desc
    end
    if water > CFG.maxWaterLevel then
        return false, "too deep (body locked in swim) -- move to the shallows | " .. desc
    end
    return true, ("wading (waterLevel=%d) | %s"):format(water, desc)
end

-- ---------------------------------------------------------------------------
-- CONTRACT: tryCatch  -> caught, itemId, isGarbage
-- v0 is a coin flip on purpose.
-- ---------------------------------------------------------------------------
function Fishing.tryCatch(character)
    if roll() > CFG.baseChance then
        return false, nil, false
    end
    if roll() < CFG.garbageOdds then
        return true, "junk_sandal", true
    end
    return true, "raw_fish", false
end

-- ---------------------------------------------------------------------------
-- Item grant -- ROUTE UNKNOWN. Try what we have and report honestly.
-- Never invents success: if no route works the catch still counts in suite
-- state, and we learn which API to use for v0.1.
-- ---------------------------------------------------------------------------
local function tryGrantItem(character, itemId)
    local okInv, inv = pcall(function() return character:getInventory() end)
    if not okInv or not inv then
        return false, "no inventory"
    end
    -- documented as Inventory:addItem(quantity, dropOnFail, destroyOnFail) --
    -- note it takes no item id, so this likely is NOT the mint route.
    if inv.addItem then
        local ok, res = pcall(function() return inv:addItem(1, true, false) end)
        if ok then return true, "inv:addItem -> " .. tostring(res) end
        return false, "inv:addItem err " .. tostring(res)
    end
    return false, "no addItem on Inventory"
end

-- ---------------------------------------------------------------------------
-- Cast lifecycle
-- ---------------------------------------------------------------------------
local function beginCast(character, name)
    local s = stateFor(name)
    if s.casting then
        log(name .. ": already casting")
        return
    end
    local can, why = Fishing.canFish(character)
    if not can then
        log(name .. ": cannot fish -- " .. why)
        return
    end
    s.casting, s.elapsed = true, 0
    log(name .. ": cast! (" .. why .. ") ... " .. CFG.castSeconds .. "s")
end

local function finishCast(character, name)
    local s = stateFor(name)
    s.casting, s.elapsed = false, 0

    local caught, itemId, isGarbage = Fishing.tryCatch(character)
    if not caught then
        log(name .. ": nothing bit.")
        return
    end

    if isGarbage then s.garbage = s.garbage + 1 else s.caught = s.caught + 1 end
    local granted, how = tryGrantItem(character, itemId)
    log(("%s: CAUGHT %s%s | grant: %s (%s) | totals fish=%d junk=%d")
        :format(name, itemId, isGarbage and " (junk)" or "",
                granted and "OK" or "FAILED", how, s.caught, s.garbage))
end

-- ---------------------------------------------------------------------------
-- Input. onKeyDown is documented but unverified -- the logger below both
-- discovers real keycodes and proves the hook fires.
-- ---------------------------------------------------------------------------
if type(registerHandler) == "function" then
    local typeLogged = false
    registerHandler("onKeyDown", function(keyCode)
        -- Diagnose the argument's real type ONCE. v0.1 lost a run because the
        -- handler fired on F (scancode 33, confirmed in the log) but the equality
        -- test never matched -- a strong sign keyCode is not a plain number.
        if not typeLogged then
            typeLogged = true
            log(("keyCode type=%s value=%s"):format(type(keyCode), tostring(keyCode)))
        end
        if CFG.logKeycodes then
            log("keycode " .. tostring(keyCode))
        end
        -- Type-tolerant compare: accept number, numeric string, or anything
        -- whose tostring() is the scancode.
        local kc = tonumber(keyCode) or tonumber(tostring(keyCode))
        if kc ~= CFG.fishKey then return end
        log("FISH KEY MATCHED (" .. tostring(kc) .. ")")

        local ok, character = pcall(function() return getSelectedCharacter() end)
        if not ok or not character then
            log("no character selected -- click one first")
            return
        end
        local okN, name = pcall(function() return character:getName() end)
        name = (okN and name) or "?"

        -- SURVEY: dump the water state on every press, wherever you stand.
        -- Press on dry land, at the shoreline, ankle-deep, and while swimming --
        -- the log then shows exactly which signal separates wading from
        -- swimming, and the threshold stops being a guess.
        if CFG.surveyMode then
            log(("SURVEY %s | %s"):format(name, describe(Fishing.readWaterState(character))))
        end

        beginCast(character, name)
    end)
    log("input hook armed -- press F while a swimming character is selected")

    -- Timer: onCharsUpdate is the sim tick. Frame delta is not exposed, so v0
    -- approximates with a tick count; the WSM will own real time later.
    local TICKS_PER_SEC = 30
    local target = CFG.castSeconds * TICKS_PER_SEC
    registerHandler("onCharsUpdate", function()
        for name, s in pairs(Fishing.state) do
            if s.casting then
                s.elapsed = s.elapsed + 1
                if s.elapsed >= target then
                    local ok, character = pcall(function() return getSelectedCharacter() end)
                    if ok and character then
                        finishCast(character, name)
                    else
                        s.casting = false
                    end
                end
            end
        end
    end)
else
    log("registerHandler unavailable -- fishing inert")
end

log("Fishing v0 loaded. Select a character, get in water, press F.")
