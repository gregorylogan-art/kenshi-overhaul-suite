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
    fishKey     = 33,    -- OIS/DirectInput scancode. 33 = F. Confirmed by the
                         -- keycode logger below -- press keys and read the log.
    castSeconds = 3.0,   -- how long a cast takes
    baseChance  = 0.25,  -- v0: flat 25% (v1 will fold in skill)
    garbageOdds = 0.40,  -- of successful catches, share that are junk
    logKeycodes = true,  -- discovery aid: log every keycode pressed
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
function Fishing.canFish(character)
    if not character then return false, "no character" end

    local ok, stats = pcall(function() return character:getStats() end)
    if not ok or not stats then return false, "no stats" end

    local okSwim, swimming = pcall(function() return stats.swimming end)
    if not okSwim then return false, "swimming unreadable" end

    local water = 0
    local okW, w = pcall(function() return character:getWaterLevel() end)
    if okW and type(w) == "number" then water = w end

    local inWater = (type(swimming) == "number" and swimming > 0)
                 or (swimming == true)
                 or (water > 0)
    if not inWater then
        return false, ("not in water (swimming=%s waterLevel=%s)"):format(tostring(swimming), tostring(water))
    end
    return true, ("in water (swimming=%s waterLevel=%s)"):format(tostring(swimming), tostring(water))
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
    registerHandler("onKeyDown", function(keyCode)
        if CFG.logKeycodes then
            log("keycode " .. tostring(keyCode))
        end
        if keyCode ~= CFG.fishKey then return end

        local ok, character = pcall(function() return getSelectedCharacter() end)
        if not ok or not character then
            log("no character selected -- click one first")
            return
        end
        local okN, name = pcall(function() return character:getName() end)
        beginCast(character, (okN and name) or "?")
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
