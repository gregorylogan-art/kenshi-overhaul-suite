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
    castSeconds = 5.0,   -- Greg v1.1: 3s felt too quick for a deliberate act

    -- OUTCOME TABLE (Greg v1.1). Junk dominates deliberately: fishing must not
    -- be a cheap money loop, so the common result is worthless trash and fish
    -- are the payoff. Skill will later shift junk->fish (issue #14).
    --   5%  nothing   80%  junk   15%  fish
    -- Cumulative thresholds on ONE roll, so the numbers here are literally the
    -- probabilities -- no compounding to reason about.
    pctNothing = 0.05,
    pctJunk    = 0.80,   -- fish is the remainder (0.15)
    -- Standstill radius (squared, world units). Kenshi world units are large;
    -- ~2.5 units of drift is generous enough to survive idle sway but cancels
    -- on a real walk. Tune from the "cast broken -- you moved" logs.
    moveToleranceSq = 6.0,
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
        s = { casting = false, elapsed = 0, caught = 0, garbage = 0, anchor = nil }
        Fishing.state[name] = s
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Position helpers. Character:getPosition() is VERIFIED and returns a Vector3
-- as a Lua table; handle both {x=,y=,z=} and {1,2,3} shapes since we have not
-- confirmed which.
-- ---------------------------------------------------------------------------
local function readPos(character)
    local ok, p = pcall(function() return character:getPosition() end)
    if not ok or type(p) ~= "table" then return nil end
    local x = p.x or p[1]
    local y = p.y or p[2]
    local z = p.z or p[3]
    if type(x) ~= "number" or type(z) ~= "number" then return nil end
    return { x = x, y = y or 0, z = z }
end

local function distSq(a, b)
    if not a or not b then return 0 end
    local dx, dy, dz = a.x - b.x, (a.y or 0) - (b.y or 0), a.z - b.z
    return dx * dx + dy * dy + dz * dz
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
-- Junk pool: real, cheap vanilla Kenshi items (Greg's picks -- these read as
-- authentic riverbed trash). One is chosen at random per junk pull.
--
-- RESOLVED CATEGORIES (measured live): 2 = weapons, 3 = clothing/armour,
-- 4 = food/materials. "Sandals" was NOT FOUND in any category, so the vanilla
-- name differs -- alternates are tried below and the pool self-prunes to
-- whatever actually exists.
local JUNK_CANDIDATES = {
    "Iron Club",        -- category 2, confirmed
    "Straw Hat",        -- category 3, confirmed
    "Rag Loincloth",    -- category 3, confirmed
    -- footwear name unknown; first one that resolves wins
    "Sandles", "Leather Sandals", "Cloth Sandals", "Shoddy Sandals",
    "Rag Shirt", "Dustcoat", "Shirt",
}
local JUNK_POOL = nil   -- built on first use from what actually resolves

function Fishing.tryCatch(character)
    -- One roll against cumulative bands: 5% nothing | 80% junk | 15% fish.
    local r = roll()
    if r < CFG.pctNothing then
        return false, nil, false
    end
    if r < CFG.pctNothing + CFG.pctJunk then
        -- Build the pool once, keeping only names that genuinely resolve, so a
        -- bad guess degrades to "fewer junk types" instead of a failed grant.
        if not JUNK_POOL then
            JUNK_POOL = {}
            for _, n in ipairs(JUNK_CANDIDATES) do
                if lookupItemData(character, n) then JUNK_POOL[#JUNK_POOL + 1] = n end
            end
            log("junk pool resolved: " .. (#JUNK_POOL > 0 and table.concat(JUNK_POOL, ", ") or "NONE"))
        end
        if #JUNK_POOL > 0 then
            return true, JUNK_POOL[math.random(#JUNK_POOL)], true
        end
    end
    return true, "raw_fish", false
end

-- ---------------------------------------------------------------------------
-- Item grant -- ROUTE UNKNOWN. Try what we have and report honestly.
-- Never invents success: if no route works the catch still counts in suite
-- state, and we learn which API to use for v0.1.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- ITEM MINT + GRANT -- SOLVED 2026-08-01, entirely by reading argument errors.
-- The documented signature was wrong; this is the real one:
--
--   factory:createItem(gameData, hand, gameData?, gameData?, number, Faction?)
--                      ^itemType ^owner  nil ok     nil ok     0      nil ok
--   inv:addItem(item, 1, true, false) -> true
--
-- Reaching the item database (validated -- GameWorld.gamedata RESOLVES but
-- cannot answer queries, so it must be tested, not assumed):
--   character:getFaction():getData().sourceContainer -> GameDataContainer
--   container:getDataByName(<name>, 4)               -> GameData   (4 = items)
-- ---------------------------------------------------------------------------

-- Real vanilla item names. "Dried Fish" ships with Kenshi (Newwworld.mod), so
-- Phase 1 needs no FCS item authoring at all.
local ITEM_NAMES = {
    raw_fish     = "Dried Fish",
    junk_sandal  = "Iron Plates",   -- placeholder "rusted scrap" until FCS junk exists
}

local ITEM_CATEGORY = 4

local function getContainer(character)
    local ok, c = pcall(function()
        return character:getFaction():getData().sourceContainer
    end)
    if ok and c then return c end
    return nil
end

local gameDataCache = {}

local function lookupItemData(character, itemId)
    local name = ITEM_NAMES[itemId] or itemId
    if gameDataCache[name] ~= nil then return gameDataCache[name] or nil end

    local container = getContainer(character)
    if not container then return nil end

    -- Category 4 holds food/materials ("Dried Fish" lives there), but clothing
    -- and weapons are almost certainly elsewhere. Try 4 first, then sweep --
    -- cached, so the sweep happens at most once per item name.
    local function tryCat(cat)
        local ok, gd = pcall(function() return container:getDataByName(name, cat) end)
        if ok and gd then return gd end
        return nil
    end

    local gd = tryCat(ITEM_CATEGORY)
    local foundCat = ITEM_CATEGORY
    if not gd then
        for cat = 0, 40 do
            if cat ~= ITEM_CATEGORY then
                gd = tryCat(cat)
                if gd then foundCat = cat break end
            end
        end
    end

    if gd then
        log(("item resolved: %-16s category=%d"):format(name, foundCat))
    else
        log("item NOT FOUND in any category: " .. name)
    end
    gameDataCache[name] = gd or false
    return gd
end

local function tryGrantItem(character, itemId)
    local okInv, inv = pcall(function() return character:getInventory() end)
    if not okInv or not inv then return false, "no inventory" end

    local gd = lookupItemData(character, itemId)
    if not gd then return false, "no GameData for " .. tostring(ITEM_NAMES[itemId] or itemId) end

    local okH, hand = pcall(function() return inv:getHandle() end)
    if not okH or not hand then return false, "no inventory handle" end

    -- The number slot is a LEVEL. 0 works for food/materials but returns nil for
    -- weapons (Iron Club, category 2) -- gear presumably needs a real quality
    -- level. Try a few until one yields an Item.
    local factory = getRootObjectFactory()
    local item
    for _, lvl in ipairs({ 0, 1, -1, 2 }) do
        local ok, made = pcall(function()
            return factory:createItem(gd, hand, nil, nil, lvl, nil)
        end)
        if ok and made then item = made break end
    end
    if not item then
        return false, "createItem returned nil at every level"
    end

    local okAdd, res = pcall(function() return inv:addItem(item, 1, true, false) end)
    if okAdd and res then
        return true, ITEM_NAMES[itemId] or itemId
    end
    -- addItem returning false is usually NO ROOM -- normal game behaviour once a
    -- pack fills with junk, not a code fault. Say so rather than crying bug.
    if okAdd then
        return false, "no room in inventory (drop some junk)"
    end
    return false, "addItem error: " .. tostring(res)
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
    -- Anchor the cast to a spot. Moving away cancels it (see the tick handler):
    -- fishing is a deliberate act you stand still for, not something done at a jog.
    s.anchor = readPos(character)
    log(name .. ": cast! (" .. why .. ") ... hold still " .. CFG.castSeconds .. "s")
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
-- RELOAD SAFETY. `dofile` re-runs this file, and each run used to register
-- ANOTHER pair of handlers -- so old copies of the script kept running beside
-- the new one. Observed live: two different tallies (fish=17 and fish=6) and a
-- pre-fix grant error resurfacing from a stale closure. Unregister anything a
-- previous load left behind before wiring new handlers.
if Fishing._handlers and type(unregisterHandler) == "function" then
    for _, hid in ipairs(Fishing._handlers) do pcall(unregisterHandler, hid) end
    log("unregistered " .. #Fishing._handlers .. " handler(s) from a previous load")
end
Fishing._handlers = {}

if type(registerHandler) == "function" then
    local typeLogged = false
    Fishing._handlers[#Fishing._handlers + 1] = registerHandler("onKeyDown", function(keyCode)
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
    log("input hook armed -- press G while WADING (shallow water) with a character selected")

    -- Timer: onCharsUpdate is the sim tick. Frame delta is not exposed, so v0
    -- counts ticks. MEASURED from the live log: a "3s" cast completed in ~0.9s
    -- with a 30/sec assumption, so onCharsUpdate actually fires ~100/sec.
    -- (Fourth time a measurement corrected an assumption -- the WSM will own
    -- real time properly rather than counting ticks.)
    local TICKS_PER_SEC = 100
    local target = CFG.castSeconds * TICKS_PER_SEC
    Fishing._handlers[#Fishing._handlers + 1] = registerHandler("onCharsUpdate", function()
        for name, s in pairs(Fishing.state) do
            if s.casting then
                s.elapsed = s.elapsed + 1

                local ok, character = pcall(function() return getSelectedCharacter() end)
                if not ok or not character then
                    s.casting, s.anchor = false, nil
                else
                    -- STANDSTILL: drifting off the anchor cancels the cast.
                    if s.anchor then
                        local now = readPos(character)
                        if now and distSq(now, s.anchor) > CFG.moveToleranceSq then
                            s.casting, s.elapsed, s.anchor = false, 0, nil
                            log(name .. ": cast broken -- you moved. hold still to fish.")
                        end
                    end
                    -- Water can also change underfoot mid-cast (waded out too deep).
                    if s.casting then
                        local can, why = Fishing.canFish(character)
                        if not can then
                            s.casting, s.elapsed, s.anchor = false, 0, nil
                            log(name .. ": cast broken -- " .. why)
                        elseif s.elapsed >= target then
                            finishCast(character, name)
                        end
                    end
                end
            end
        end
    end)
else
    log("registerHandler unavailable -- fishing inert")
end

log("Fishing v1 loaded. Select a character, WADE into shallow water, hold still, press G.")
