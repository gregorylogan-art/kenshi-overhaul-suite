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
    -- Standstill radius SQUARED. Was 6.0 (~2.4 units) -- far too tight for real
    -- Kenshi play, where bandits and bone dogs mean you are rarely still. 100
    -- (~10 units) tolerates repositioning and shuffle but still cancels on a
    -- genuine walk. The break message now logs the ACTUAL drift, so tune from
    -- those numbers rather than from my guess at world scale.
    moveToleranceSq = 100.0,
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
Fishing._fishName = nil   -- cleared on reload: a newly enabled FCS mod must re-resolve
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
-- SEEDED. math.random was never seeded, so every session produced the IDENTICAL
-- loot sequence (bowl, book, bowl, freeze -- twice in a row). That made the
-- freeze perfectly reproducible, which was lucky for diagnosis but is wrong for
-- play. os.time may be sandboxed away, so fall back to a game-derived value.
do
    local seed
    local okT, t = pcall(function() return os.time() end)
    if okT and type(t) == "number" then seed = t end
    if not seed then
        local okW, w = pcall(function() return getGameWorld() end)
        if okW and w then seed = tonumber(tostring(w):match("%x+$") or "", 16) end
    end
    pcall(math.randomseed, seed or 20260802)
    for _ = 1, 5 do pcall(math.random) end   -- discard the weak first values
end

local function roll() return math.random() end

-- ---------------------------------------------------------------------------
-- CONTRACT: canFish
-- Water test uses waterLevel ONLY. `swimming` is a LAGGING ACCUMULATOR (read
-- 12.91 on dry land), so gating on it would block fishing everywhere. This
-- docstring previously claimed the opposite -- corrected after red-team review.
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
-- FORWARD DECLARATIONS. Lua locals are invisible above their declaration, and
-- tryCatch (below) uses both of these while they are defined further down the
-- file -- which made them nil and threw
--   "bad argument #1 to 'ipairs' (table expected, got nil)"
-- every cast, so no catch ever completed. Declared here, assigned later.
local lookupItemData

-- Preferred fish, best first; first that RESOLVES wins, so fishing adopts the
-- FCS items automatically and falls back to vanilla Dried Fish otherwise.
local FISH_PREFERENCE = {
    "Small Fish",   -- FCS: 11-KenshiOverhaulSuite.mod
    "Raw Fish",     -- FCS: 10-KenshiOverhaulSuite.mod
    "Dried Fish",   -- vanilla fallback
}

-- ############################################################################
-- JUNK GRANTING DISABLED -- SUSPECTED MALFORMED ITEMS BREAK THE INVENTORY GUI
--
-- Symptom (Greg): character stops taking orders, INVENTORY WILL NOT OPEN, and
-- the stats screen flashes open then closes. Game and rest of GUI keep running.
-- That reads as the inventory UI failing to RENDER something, not as broken
-- stats.
--
-- Suspect: we mint everything with createItem(gd, hand, nil,nil, LEVEL=0, nil).
-- Category-4 FOOD (Dried Fish / Raw Fish / Small Fish) displays perfectly, but
-- clothing and misc (Straw Hat, Rag Loincloth, Wooden Bowl, Cup, Book -- cat 3
-- and friends) may need a real level or the GameData slots we pass as nil.
-- Weapons already proved this: they return nil at every level.
--
-- Until it is understood, junk grants are OFF and only proven-safe food is
-- granted. A junk pull now yields nothing rather than risking the save.
-- ############################################################################
local ALLOW_JUNK_GRANT = true   -- TEST B: re-enabled WITH the hasRoomForItem() guard in place

local JUNK_CANDIDATES = {
    -- confirmed resolving
    -- "Iron Club" REMOVED: createItem returns nil at every level for weapons
    -- (category 2). Gear likely needs a different creation path than food.
    "Straw Hat",            -- category 3
    "Rag Loincloth",        -- category 3
    -- Greg's riverbed-trash picks: all equally worthless, which is the point
    "Empty Rum Bottle", "Cup", "Wooden Bowl", "Damaged Book",
    -- spelling alternates; the pool self-prunes to whatever exists
    "Rum Bottle", "Bottle", "Bowl", "Book", "Damaged book",
}
local JUNK_POOL = nil   -- built on first use from what actually resolves

function Fishing.tryCatch(character)
    -- SKILL NOW ACTUALLY APPLIES. The skill model existed but was called from
    -- nowhere except simulate(), so XP rose and changed nothing -- the entire
    -- "class fantasy" was inert. Bands are now derived from live skills when
    -- 19_fishing_skill.lua is loaded, and fall back to the flat config if not.
    local pctNothing, pctJunk = CFG.pctNothing, CFG.pctJunk
    if Fishing.computeOdds and Fishing.readSkill then
        local okOdds, n, j = pcall(function()
            return Fishing.computeOdds(
                Fishing.readSkill(character, "precisionShooting"),
                Fishing.readSkill(character, "swimming"),
                Fishing.readSkill(character, "labouring"))
        end)
        if okOdds and type(n) == "number" and type(j) == "number" then
            pctNothing, pctJunk = n, j
        end
    end

    -- One roll against cumulative bands: nothing | junk | fish (the remainder).
    local r = roll()
    if r < pctNothing then
        return false, nil, false
    end
    -- The junk band is TERMINAL. It used to fall through to fish whenever junk
    -- could not be granted, which silently turned the shipped distribution into
    -- 5% nothing / 95% FISH -- the exact opposite of the design, and a direct
    -- contradiction of the safety banner above. A junk roll that cannot be
    -- fulfilled now yields nothing.
    if r < pctNothing + pctJunk then
        if not ALLOW_JUNK_GRANT then return false, nil, false end
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
        return false, nil, false   -- empty pool must NOT become a fish
    end
    -- Resolve the best available fish once; falls back down the preference list.
    if not Fishing._fishName then
        for _, n in ipairs(FISH_PREFERENCE) do
            if lookupItemData(character, n) then
                Fishing._fishName = n
                log("fish item in use: " .. n)
                break
            end
        end
        Fishing._fishName = Fishing._fishName or "Dried Fish"
    end
    return true, Fishing._fishName, false
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
-- Preferred fish, best first. Each name is tried in order and the first that
-- RESOLVES wins, so the moment the FCS items are authored fishing switches to
-- them automatically -- and until then it keeps working on vanilla Dried Fish.
-- No code change needed on either side of the FCS session.
-- (FISH_PREFERENCE is declared near the top -- Lua scoping, see the note there.)

-- ---------------------------------------------------------------------------
-- COOKING SINK -- implemented in LUA because FCS has no failure-chance field.
-- Greg checked: recipes support ingredients but no "probability to burn".
-- So the burn lives here instead, and the design survives intact.
--
-- Watches inventory for a cooked fish appearing and rolls to spoil it into the
-- burnt item. Names are resolved live, so whatever FCS actually produced wins.
-- ---------------------------------------------------------------------------
-- NOTE: getDataByName is CASE-SENSITIVE. FCS saved item 12 as "Cooked fish"
-- (lowercase f), which is why "Cooked Fish" silently failed to resolve. Always
-- list case variants rather than assuming title case.
local COOK_CFG = {
    enabled     = true,
    burnChance  = 0.20,          -- 20% of cooks are ruined
    cookedNames = { "Cooked fish", "Cooked Fish" },
    burntNames  = { "Burnt fish", "Burnt Fish", "Burnt meat", "Burnt Meat",
                    "Burned fish", "Burned Fish" },
}

local ITEM_NAMES = {
    junk_sandal = "Iron Plates",   -- legacy alias, unused now
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

-- assigned to the forward-declared local above (not a new local)
lookupItemData = function(character, itemId)
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
        -- Only the three MEASURED categories (2 weapons, 3 clothing, 4 food).
        -- The old 0..40 sweep fed 41 fabricated enum values into a C++ arg on
        -- every miss -- the same class gen_probes.py bans, and pcall cannot
        -- catch a native fault.
        for _, cat in ipairs({ 3, 2 }) do
            do
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
    -- LOG-AS-CURSOR. A hard freeze leaves no error, so print the intent BEFORE
    -- acting: whatever appears last in the log is what killed the game. This is
    -- the same technique that identified the container crash class, and it is
    -- how we will name the item behind the deterministic cast-4 freeze.
    log("GRANT-ATTEMPT: " .. tostring(itemId))
    local okInv, inv = pcall(function() return character:getInventory() end)
    if not okInv or not inv then return false, "no inventory" end

    local gd = lookupItemData(character, itemId)
    if not gd then return false, "no GameData for " .. tostring(ITEM_NAMES[itemId] or itemId) end

    local okH, hand = pcall(function() return inv:getHandle() end)
    if not okH or not hand then return false, "no inventory handle" end

    -- CHECK ROOM *BEFORE* MINTING. Previously we created the Item first and, if
    -- addItem failed, simply dropped the reference -- but the Item was created
    -- against the INVENTORY'S HANDLE, so nothing destroys it and Lua GC cannot
    -- free an engine-side object. It stays registered to the inventory with no
    -- slot.
    --
    -- LEADING THEORY for issue #21 (inventory GUI refuses to open): food is a
    -- 1x1 item that essentially always places, while Straw Hat / Rag Loincloth
    -- are multi-cell and are exactly what fails placement -- leaving orphaned
    -- Items the GUI then cannot lay out. That fits the symptom far better than
    -- "malformed clothing", and explains why food never misbehaved.
    -- FAIL-CLOSED. The previous version only refused when the check explicitly
    -- returned false -- so if hasRoomForItem errored, was absent, or returned
    -- nil, we minted anyway and could still orphan an item. That matches what
    -- Greg saw: a DETERMINISTIC freeze on cast 4 every session (math.random was
    -- unseeded, so the same junk sequence repeats), i.e. one specific item that
    -- would not fit. If we cannot PROVE there is room, we do not mint.
    if not inv.hasRoomForItem then
        return false, "hasRoomForItem absent -- refusing to mint (cannot prove room)"
    end
    local okRoom, room = pcall(function() return inv:hasRoomForItem(gd) end)
    if not okRoom then
        return false, "room check errored: " .. tostring(room)
    end
    if room ~= true then
        return false, ("no room (hasRoomForItem=%s)"):format(tostring(room))
    end

    -- The number slot is a LEVEL. 0 works for food/materials but returns nil for
    -- weapons (Iron Club, category 2) -- gear presumably needs a real quality
    -- level. -1 was removed: feeding an out-of-domain value into a C++ level
    -- parameter is the same fabricated-argument class gen_probes.py bans.
    local factory = getRootObjectFactory()
    local item
    for _, lvl in ipairs({ 0, 1, 2 }) do
        local ok, made = pcall(function()
            return factory:createItem(gd, hand, nil, nil, lvl, nil)
        end)
        if ok and made then item = made break end
    end
    if not item then
        return false, "createItem returned nil at every level"
    end

    -- addItem(item, quantity, dropOnFail, destroyOnFail).
    --
    -- We used to pass dropOnFail=TRUE, destroyOnFail=FALSE -- i.e. "if it does
    -- not fit, drop it on the ground". The character doing the fishing is
    -- STANDING IN WATER, so that asked the engine to place a world object at a
    -- position that may have no valid ground, every time a pack filled up.
    -- That fits issue #21 far better than any single bad item: the freeze was
    -- DETERMINISTIC on cast 4 (unseeded RNG replays the same junk sequence, so
    -- the pack fills at the same point every run), it broke the character AND
    -- both of its detail screens rather than just the inventory layout, and it
    -- only ever happened while fishing.
    --
    -- Inverted: if it does not fit, DESTROY it. A refused catch is correct,
    -- honest behaviour -- no orphan, no ground clutter, no drop-into-water.
    local okAdd, res = pcall(function() return inv:addItem(item, 1, false, true) end)
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


-- ===========================================================================
-- SKILL MODEL (merged in from 19_fishing_skill.lua)
--
-- KenshiLua SANDBOXES EACH SCRIPT. Proven live: from the console
-- `Fishing.status` resolved (defined here) while `Fishing.computeOdds`,
-- `Fishing.grantXp` and `Fishing.simulate` were all nil -- they were defined in
-- 19_fishing_skill.lua, whose `Fishing` table is a DIFFERENT table in a
-- different environment. Cross-script sharing via a global does not work.
--
-- This also explains why XP silently never fired: Fishing.grantXp was always
-- nil on this side, and the call site guarded with `if Fishing.grantXp`, so it
-- failed invisibly rather than erroring.
--
-- One file = one environment = the model actually applies. The WSM needs a
-- different answer to this before other systems can depend on it.
-- ===========================================================================

Fishing = Fishing or {}

-- Stat IDs MEASURED live via 18_stat_probe.lua (38 named stats enumerated).
-- These are read from the running game, not guessed.
Fishing.STAT = {
    labouring         = 3,
    swimming          = 23,
    perception        = 24,
    precisionShooting = 36,
}

Fishing.SKILL_CFG = {
    -- base bands (must sum to 1 with fish as remainder)
    baseNothing = 0.05,
    baseJunk    = 0.80,

    -- per-level junk reduction (fractions, i.e. 0.003 = 0.3%)
    junkPerPrecision = 0.0005,
    junkPerSwimming  = 0.0010,
    junkPerLabouring = 0.0030,

    -- per-level nothing reduction
    nothingPerPrecision = 0.0002,

    -- floors so high skill never fully removes variety
    minJunk    = 0.05,
    minNothing = 0.005,

    -- cast speed
    baseCastSeconds   = 5.0,
    castSecPerLabour  = 0.01,
    minCastSeconds    = 2.0,

    -- XP granted per completed cast (small; fishing is not a power-level route).
    -- Tuned live by Greg after watching the skill tab move: Labouring leads
    -- because fishing is graft, Precision Shooting and Swimming are secondary
    -- side-effects, Perception is a trickle.
    xpPerCast = { labouring = 1.0, precisionShooting = 0.4, swimming = 0.3, perception = 0.25 },
}

-- ---------------------------------------------------------------------------
-- PURE MATH -- no game objects, so it is unit-testable from the console.
-- ---------------------------------------------------------------------------
function Fishing.computeOdds(precision, swimming, labouring)
    local C = Fishing.SKILL_CFG
    precision = precision or 0
    swimming  = swimming  or 0
    labouring = labouring or 0

    local junkCut = precision * C.junkPerPrecision
                  + swimming  * C.junkPerSwimming
                  + labouring * C.junkPerLabouring
    local nothingCut = precision * C.nothingPerPrecision

    local junk    = math.max(C.minJunk,    C.baseJunk    - junkCut)
    local nothing = math.max(C.minNothing, C.baseNothing - nothingCut)
    local fish    = 1.0 - junk - nothing
    if fish < 0 then fish = 0 end
    return nothing, junk, fish
end

function Fishing.computeCastSeconds(labouring)
    local C = Fishing.SKILL_CFG
    return math.max(C.minCastSeconds,
                    C.baseCastSeconds - (labouring or 0) * C.castSecPerLabour)
end

-- ---------------------------------------------------------------------------
-- SIMULATION -- the answer to "XP takes too long to test".
--   Fishing.simulate()            -- curve at 0/25/50/75/100
--   Fishing.simulate(60)          -- one level across all three skills
--   Fishing.simulate(10, 80, 40)  -- precision, swimming, labouring
-- ---------------------------------------------------------------------------
function Fishing.simulate(a, b, c)
    local function row(p, s, l)
        local n, j, f = Fishing.computeOdds(p, s, l)
        log(("prec=%-3d swim=%-3d labour=%-3d | nothing %5.1f%%  junk %5.1f%%  fish %5.1f%%  cast %.2fs")
            :format(p, s, l, n * 100, j * 100, f * 100, Fishing.computeCastSeconds(l)))
    end
    log("=========== FISHING CURVE ===========")
    if a and b and c then
        row(a, b, c)
    elseif a then
        row(a, a, a)
    else
        for _, lvl in ipairs({ 0, 10, 25, 50, 75, 100 }) do row(lvl, lvl, lvl) end
    end
    log("=====================================")
end

-- ---------------------------------------------------------------------------
-- LIVE READS / XP GRANTS -- only active once stat IDs are known.
-- ---------------------------------------------------------------------------
function Fishing.readSkill(character, key)
    local id = Fishing.STAT[key]
    if not id then return 0 end
    local stats = select(2, pcall(function() return character:getStats() end))
    if not stats then return 0 end
    -- unmodified=TRUE: we want the character's real skill, not the value after
    -- encumbrance/hunger penalties. Reading modified made skills appear to FALL
    -- as junk filled the pack, which would have fed distorted numbers into the
    -- odds curve.
    local ok, v = pcall(function() return stats:getStat(id, true) end)
    if ok and type(v) == "number" then return v end
    return 0
end

-- Grant XP for a completed cast and REPORT it, so we can see the skill tab
-- actually move rather than trusting that it did.
-- ############################################################################
-- XP GRANTING IS DISABLED -- SUSPECTED CHARACTER CORRUPTION
--
-- Symptom (Greg, twice): the character stops responding to click/move orders
-- and their STATS PAGE READS EMPTY, while the rest of the GUI and the game keep
-- working normally. That is the character's CharStats being broken, not a game
-- fault -- and xpStat_eventBased is the ONLY call we make that writes into
-- character internals.
--
-- Aggravating factor: duplicate handlers meant it fired TWICE per catch, so
-- four stats x two copies = eight writes per cast.
--
-- Disabled until proven safe. Fishing works fine without it; a broken save does
-- not. Set ALLOW_XP = true only when testing deliberately, on an expendable
-- character.
-- ############################################################################
-- ISOLATION TEST A (2026-08-01): re-enabled ALONE, with junk grants still OFF.
-- Baseline confirmed stable first: food-only granting, no console reloads, gave
-- 1 cast = 1 fish with a working inventory and stats page. So if the character
-- breaks now, XP is the cause; if it stays healthy, the fault is in the junk
-- item path. One variable at a time.
-- XP DISABLED -- PRIME SUSPECT for the broken character.
-- Evidence: Fishing.testGrant (items, NO xp) left the inventory and stats
-- screens working. Fishing (items + XP) broke the character on the 4th cast,
-- and Greg confirms stats WERE increasing every time -- so xpStat_eventBased
-- was firing, which it never did before the merge (grantXp was nil).
-- xpStat_eventBased is the only call we make that writes into character
-- internals, and the symptom is character-internal: no orders, no inventory,
-- no stats page, world unaffected.
-- UPDATE: XP is now EXONERATED, not merely suspected. The freeze reproduced on
-- cast 4 with ALLOW_XP already false, so the XP write cannot be the cause. It
-- stays off for exactly one run so the drop-into-water fix is tested as a single
-- variable, then goes back on. Fishing.setXp(true) flips it live -- no redeploy,
-- no reload, so both tests fit in one session.
local ALLOW_XP = false

-- Fishing.setXp(true|false) -- toggle XP granting at runtime.
function Fishing.setXp(on)
    ALLOW_XP = (on == true)
    log("xp granting -> " .. tostring(ALLOW_XP))
    return ALLOW_XP
end

function Fishing.grantXp(character)
    if not ALLOW_XP then return "xp disabled (suspected character corruption)" end
    local okS, stats = pcall(function() return character:getStats() end)
    if not okS or not stats then return "no stats" end

    local parts = {}
    for _, key in ipairs({ "labouring", "swimming", "precisionShooting", "perception" }) do
        local id = Fishing.STAT[key]
        local amount = Fishing.SKILL_CFG.xpPerCast[key]
        if id and amount then
            local before = select(2, pcall(function() return stats:getStat(id, true) end))
            local ok, err = pcall(function() stats:xpStat_eventBased(id, amount) end)
            local after = select(2, pcall(function() return stats:getStat(id, true) end))
            if ok then
                parts[#parts + 1] = ("%s %.3f->%.3f"):format(key, before or -1, after or -1)
            else
                parts[#parts + 1] = ("%s ERR(%s)"):format(key, tostring(err))
            end
        end
    end
    return table.concat(parts, "  ")
end

-- Console helper: prove XP lands without waiting on catches.
--   Fishing.testXp()      one grant
--   Fishing.testXp(200)   200 grants, to make the skill tab visibly move
function Fishing.testXp(times)
    local ok, char = pcall(function() return getSelectedCharacter() end)
    if not ok or not char then log("select a character first") return end
    times = times or 1
    local last
    for _ = 1, times do last = Fishing.grantXp(char) end
    log(("granted x%d -> %s"):format(times, tostring(last)))
    log("now open the character's SKILLS tab and look at Labouring / Swimming /")
    log("Precision Shooting / Perception")
end


-- ---------------------------------------------------------------------------
-- TEST COMMANDS -- verify each part WITHOUT wading around hoping to see things.
-- Blind play-testing is slow and proves nothing when a result is random; these
-- answer each question directly and instantly.
-- ---------------------------------------------------------------------------

-- Fishing.status() -- is everything wired? Answers in one line each.
function Fishing.status()
    local ok, c = pcall(function() return getSelectedCharacter() end)
    log("---------- FISHING STATUS ----------")
    log("selected character : " .. (ok and c and tostring((select(2, pcall(function() return c:getName() end)))) or "NONE (click one)"))
    if ok and c then
        local can, why = Fishing.canFish(c)
        log("can fish now       : " .. tostring(can) .. "  (" .. tostring(why) .. ")")
    end
    log("junk granting      : " .. tostring(ALLOW_JUNK_GRANT))
    log("skill model wired  : " .. tostring(Fishing.computeOdds ~= nil))
    log("xp granting        : " .. tostring(Fishing.grantXp ~= nil))
    log("fish item in use   : " .. tostring(Fishing._fishName or "(unresolved)"))
    if Fishing.computeOdds and ok and c then
        local n, j, f = Fishing.computeOdds(
            Fishing.readSkill(c, "precisionShooting"),
            Fishing.readSkill(c, "swimming"),
            Fishing.readSkill(c, "labouring"))
        log(("live odds          : nothing %.1f%%  junk %.1f%%  fish %.1f%%")
            :format(n * 100, j * 100, f * 100))
    end
    for nm, s in pairs(Fishing.state) do
        log(("state[%s]: casting=%s fish=%d junk=%d"):format(nm, tostring(s.casting), s.caught, s.garbage))
    end
    log("-----------------------------------")
end

-- Fishing.testGrant("Straw Hat") -- grant ONE named item immediately.
-- Proves the mint+grant path (and the room check) with no fishing, no waiting,
-- no randomness. This is how junk gets tested instead of hoping for an 80% roll.
function Fishing.testGrant(itemName)
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then log("testGrant: select a character first") return end
    itemName = itemName or "Straw Hat"
    local granted, how = tryGrantItem(c, itemName)
    log(("testGrant(%q) -> %s (%s)"):format(itemName, granted and "OK" or "FAILED", tostring(how)))
    return granted
end

-- Fishing.testRoll(200) -- roll the outcome table N times and report the actual
-- distribution. Verifies the 5/80/15 split (and skill's effect on it) in one
-- second instead of a hundred casts.
function Fishing.testRoll(n)
    n = n or 200
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then log("testRoll: select a character first") return end
    local none, junk, fish = 0, 0, 0
    for _ = 1, n do
        local caught, _, isJunk = Fishing.tryCatch(c)
        if not caught then none = none + 1
        elseif isJunk then junk = junk + 1
        else fish = fish + 1 end
    end
    log(("testRoll(%d): nothing %.1f%%  junk %.1f%%  fish %.1f%%")
        :format(n, none / n * 100, junk / n * 100, fish / n * 100))
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

    -- Train what the activity uses: Labouring, Swimming, Precision Shooting and
    -- Perception (stat ids measured live). Precision Shooting is a deliberate
    -- back door -- same spirit as hauling heavy junk building Strength.
    -- pcall-wrapped: grantXp can throw (its before/after values come from
    -- select(2, pcall(...)), which yields an ERROR STRING on failure, and that
    -- string then hits ("%.3f"):format). An unprotected throw here aborted the
    -- whole catch before the item was ever granted -- the cast just evaporated
    -- with no CAUGHT line.
    if Fishing.grantXp then
        local okXp, xp = pcall(Fishing.grantXp, character)
        if okXp and xp then log(name .. ": xp " .. tostring(xp))
        elseif not okXp then log(name .. ": xp ERROR " .. tostring(xp)) end
    end

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

-- GENERATION GUARD. Unregistering only works for handlers we tracked; any
-- registered by a script version that predates this guard is untracked and
-- immortal, which produced TWO live copies -- doubled casts, doubled grants and
-- two divergent tallies. Every handler now checks the generation it was born in
-- and silently retires when a newer load supersedes it, so even untrackable
-- duplicates go quiet. (A one-off full restart is still needed to clear the
-- pre-guard handlers already running.)
Fishing._generation = (Fishing._generation or 0) + 1
local MY_GEN = Fishing._generation
local function stale() return Fishing._generation ~= MY_GEN end

if type(registerHandler) == "function" then
    local typeLogged = false
    Fishing._handlers[#Fishing._handlers + 1] = registerHandler("onKeyDown", function(keyCode)
        if stale() then return end
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
        if stale() then return end
        for name, s in pairs(Fishing.state) do
            if s.casting then
                s.elapsed = s.elapsed + 1

                local ok, character = pcall(function() return getSelectedCharacter() end)
                -- The tick must only act on the character who actually cast.
                -- It previously used whoever was SELECTED, so clicking a
                -- squadmate mid-cast put the fish in the wrong inventory, broke
                -- the cast against a stranger's position, and printed the tally
                -- under the caster's name. Skip entries that are not the
                -- current selection rather than acting on them.
                -- Resolve the selected character's name PROPERLY. This used to be
                --     local okN, curName = ok and character and pcall(...)
                -- but a Lua `and` expression truncates multiple returns to ONE
                -- value, so curName was always nil, the caster check always
                -- failed, every cast was skipped, and casts hung on
                -- "already casting" forever -- never completing, never breaking.
                local curName = nil
                if ok and character then
                    local okN, n = pcall(function() return character:getName() end)
                    if okN then curName = n end
                end

                -- SAFETY VALVE: a cast may never hang. If it somehow outlives
                -- twice its own duration, drop it rather than wedge the state.
                if s.elapsed > target * 2 then
                    s.casting, s.elapsed, s.anchor = false, 0, nil
                    log(name .. ": cast timed out (stuck) -- reset")
                elseif curName and curName ~= name then
                    -- a different character is selected: leave this cast alone
                elseif not ok or not character then
                    s.casting, s.anchor = false, nil
                else
                    -- STANDSTILL: drifting off the anchor cancels the cast.
                    if s.anchor then
                        local now = readPos(character)
                        local d2 = now and distSq(now, s.anchor) or 0
                        if now and d2 > CFG.moveToleranceSq then
                            s.casting, s.elapsed, s.anchor = false, 0, nil
                            -- Report the ACTUAL drift so the tolerance is tuned
                            -- from measurement rather than my guess at Kenshi's
                            -- world-unit scale.
                            log(("%s: cast broken -- moved %.1f units (tolerance %.1f)")
                                :format(name, math.sqrt(d2), math.sqrt(CFG.moveToleranceSq)))
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
