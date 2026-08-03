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
    -- H. Scancodes here are sequential (F=33, G=34), so H=35. Collecting was
    -- console-only, which is not a feature -- a player should never need the
    -- script console to finish a gathering loop.
    collectKey  = 35,    -- H
    bagKey      = 36,    -- J -- show the catch bag on screen
    bagShowSecs = 8,     -- how long the readout lingers
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
    -- MEASURED, not guessed (live log, two fishers wading, 2026-08-02):
    --     moved 10.3 / 10.4 / 10.6 / 11.1 units  against tolerance 10.0
    -- Four cancels in six seconds, every one within 11% of the threshold, while
    -- the character was STANDING STILL in water. That is idle sway and water
    -- drift, not walking -- Kenshi characters do not hold a position to the
    -- centimetre when wading. The old value sat right on top of the noise floor,
    -- so auto-fishing died constantly and read as "the G toggle is broken".
    --
    -- 30 units clears the observed ~11-unit noise with real margin while still
    -- being a small fraction of what an actual walk covers in a 5s cast.
    moveToleranceSq = 900.0,   -- 30 units
    baseChance  = 0.25,
    garbageOdds = 0.40,
    logKeycodes = false,

    -- ####################################################################
    -- BANK CATCHES INSTEAD OF WRITING THEM INTO THE CHARACTER'S INVENTORY.
    --
    -- Greg, after the caps kept failing:
    --   "cap is the wrong call. what if i pick up 9 items... what if i have a
    --    backpack what if what if... its 85% sure its the reason harvesting is
    --    a second inventory in kenshi. im sure its one of his law in his engine."
    --
    -- He is right on both counts, and the last log settles it: only ELEVEN grant
    -- attempts and TWO fullness refusals that session, and it froze anyway. So
    -- it is not probe frequency, and no cap can help -- a cap cannot know what
    -- the player picked up, whether they wear a backpack, or what else fills the
    -- grid. Every cap I wrote was a guess about someone else's inventory.
    --
    -- The pattern worth copying is Kenshi's own: EVERY hand-gathering profession
    -- writes to a separate container and the player transfers manually. Nothing
    -- in vanilla streams items into a working character's pack, which is exactly
    -- what we were doing on a five-second loop.
    --
    -- So the loop makes ZERO inventory writes. Catches accumulate in Lua state
    -- and move across only when the player asks (Fishing.collect), as ONE
    -- deliberate bounded action instead of an automatic one every five seconds.
    -- If that stops the freeze, the engine law is real and every future system
    -- -- cooking, trade, loot -- must follow the same shape.
    -- ####################################################################
    bankCatches = true,

    -- STOP WELL BEFORE THE PACK IS FULL.
    --
    -- Greg, after four recurrences: "i 100% dont think its exp i think 100% its
    -- inventory." The evidence agrees -- every symptom is inventory-shaped (the
    -- inventory will not open, the stats screen that renders encumbrance dies,
    -- the character stops responding), and it fires only at saturation.
    --
    -- If the inventory is the trigger, then OUR OWN hasRoomForItem probes on a
    -- saturated grid are the thing poking it: we call it before every cast and
    -- again before every grant. The 19:55 freeze happened on the exact cast that
    -- first hit no-room, so even one probe against a full pack may be enough.
    --
    -- So do not walk up to the boundary at all. Count items instead -- a cheap
    -- read that does not inspect the packing grid -- and stop after this many
    -- catches on one load. The player empties, presses G, and the baseline
    -- re-takes.
    maxCatchesPerLoad = 6,

    -- Floating "what is this character doing" bar over the fisher's head.
    -- Greg: "without lua up its hard to know if im fishing or not."
    -- Kill switch: Fishing.setBar(false) if it ever misbehaves in the tick.
    showBar = true,

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

-- PUBLISH TO THE REAL GLOBAL TABLE.
--
-- KenshiLua sandboxes every script (ScriptLoader.cpp, createSandboxEnv):
--     env = {}; setmetatable(env, { __index = _G }); lua_setfenv(chunk, env)
-- Reads fall through to _G, but WRITES land in the script's private table --
-- there is no __newindex. So a bare `Fishing = ...` is invisible to everything
-- outside this file, including the in-game console and script editor:
--     [string "<editor>"]:1: attempt to index global 'Fishing' (a nil value)
--
-- That is why Fishing.probeBar() could not be run at all, and why a cross-file
-- Fishing.grantXp read nil for an entire session while appearing to be wired up.
--
-- Writing THROUGH _G escapes the private env: `_G` itself resolves via __index
-- to the real table, and an indexing assignment on it is an ordinary write.
-- pcall-wrapped so a future sandbox that also protects _G degrades to "console
-- commands unavailable" rather than failing the whole script load.
pcall(function() _G.Fishing = Fishing end)

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

-- REVERTED TO TRUE -- this is the known-working grant path, do not flip it
-- without evidence. I briefly defaulted it false on a double-registration
-- theory whose entire support was an arithmetic argument ("11 grants filled a
-- pack, so each must have yielded 2 items"). Greg then confirmed the duplication
-- had ALREADY stopped in that run -- it was duplicate HANDLERS, cured by the
-- generation guard plus a restart -- so 11 grants meant 11 items and the
-- arithmetic proved nothing. Changing a working path on a disproven theory is
-- how a real bug gets buried under a self-inflicted one.
local ADD_AFTER_CREATE = true

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

-- ---------------------------------------------------------------------------
-- PACK HEADROOM GATE  (issue #21)
-- ---------------------------------------------------------------------------
-- The observed failure, in Greg's words: "the inventory got full then the
-- character was unusable" -- no move orders, inventory refusing to open, stats
-- screen flashing shut, world running on normally.
--
-- The per-grant room check is NOT enough, and the log shows exactly why. Grant
-- 8 of 11 was correctly refused with hasRoomForItem=false, and then grants
-- 9, 10 and 11 SUCCEEDED -- because a 1x1 Small Fish still slots into gaps a
-- multi-cell item cannot use. So the pack kept accepting items right at its
-- boundary, and that boundary is where the character broke.
--
-- So stop fishing well BEFORE the boundary instead of walking up to it. The
-- probe is a multi-cell clothing item: once one of those will no longer fit,
-- the pack is effectively full even though 1x1 gaps remain, and we refuse the
-- cast outright rather than dribbling small items into the last crevices.
--
-- Deliberately fail-OPEN: if the probe cannot be resolved we allow the cast,
-- because tryGrantItem's own check is fail-CLOSED and nothing can be minted
-- without proving room there. Layered that way, an unknown degrades to "no
-- catch", never to "fishing is silently bricked".
-- PROBE ITEM CHOICE IS NOT ARBITRARY. This was "Straw Hat" and the gate never
-- fired once: the log shows eighteen consecutive grants refused with
-- hasRoomForItem=false while hasPackHeadroom() kept answering true, so auto
-- re-cast forever into a pack that could not take anything.
--
-- Straw Hat is category 3 (clothing/armour). Kenshi can place clothing in
-- EQUIPMENT slots rather than the backpack grid, so "is there room for a hat"
-- stays true long after the grid is solid. A clothing item is therefore the one
-- thing that must never be used to measure grid space.
--
-- Book is category 4 (general goods), multi-cell, and can only live in the grid.
local HEADROOM_PROBE = "Book"

-- Item count, read WITHOUT inspecting the packing grid. Returns nil if the call
-- is unavailable, so callers can tell "empty" from "unknown".
function Fishing.itemCount(character)
    if not character then return nil end
    local okInv, inv = pcall(function() return character:getInventory() end)
    if not okInv or not inv or not inv.getNumItems then return nil end
    local ok, n = pcall(function() return inv:getNumItems() end)
    if ok and type(n) == "number" then return n end
    return nil
end

-- True while this character may keep fishing on the current load.
-- Deliberately count-based rather than hasRoomForItem-based: the whole point is
-- to stop BEFORE the grid saturates, so the probe that may itself be the trigger
-- is never run against a full pack.
function Fishing.underCatchCap(s, character)
    local n = Fishing.itemCount(character)
    if not n then return true end          -- unknown -> do not block; the grant
                                           -- path still refuses without room
    if not s.baseItems then s.baseItems = n end
    -- The player emptied the pack: re-baseline downward so fishing resumes.
    if n < s.baseItems then s.baseItems = n end
    return (n - s.baseItems) < CFG.maxCatchesPerLoad
end

-- ---------------------------------------------------------------------------
-- NEVER PROBE A GRID WE ALREADY KNOW IS FULL
-- ---------------------------------------------------------------------------
-- The 20:14 log is the clearest evidence yet. Greg mashed G against a full pack
-- and got ~30 presses in 7 seconds, EACH ONE running hasRoomForItem against a
-- saturated grid, immediately before the character froze.
--
-- The catch cap did not save us because it was calibrated blind: it stopped
-- after 10 catches, but the pack SATURATES AT 15 ITEMS and he began with 9. It
-- never came close to firing, and every stop came from the hasRoomForItem
-- backstop -- i.e. from the very probe we were trying to avoid.
--
-- So remember the count at which this pack was observed full. While the pack is
-- at or above that count, refuse WITHOUT touching the grid; getNumItems() is a
-- plain count and is safe to call. When the player empties the pack the count
-- drops below the mark and probing resumes naturally.
--
-- Mashing G on a full pack now costs one cheap count per press and ZERO grid
-- probes, instead of one probe per press.
function Fishing.notePackFull(s, character)
    local n = Fishing.itemCount(character)
    if n then s.fullAtCount = n end
end

function Fishing.packKnownFull(s, character)
    if not s.fullAtCount then return false end
    local n = Fishing.itemCount(character)
    if not n then return false end          -- unknown -> fall through to the probe
    -- MARGIN OF ONE. fullAtCount is a LEARNED CAPACITY for this pack, so stop one
    -- item short of the count that was observed saturated. That way the next load
    -- halts BEFORE reaching the state under suspicion, instead of rediscovering
    -- it with another probe every time.
    local limit = s.fullAtCount - 1
    if n < limit then
        s.fullAtCount = nil                 -- room was made; probe again
        return false
    end
    return true
end

function Fishing.hasPackHeadroom(character)
    if not character then return true end
    local okInv, inv = pcall(function() return character:getInventory() end)
    if not okInv or not inv or not inv.hasRoomForItem then return true end
    local gd = lookupItemData(character, HEADROOM_PROBE)
    if not gd then return true end
    local ok, room = pcall(function() return inv:hasRoomForItem(gd) end)
    if not ok then return true end
    return room == true
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

    -- ####################################################################
    -- WE WERE REGISTERING EVERY ITEM TWICE. This is issue #21's real cause.
    --
    -- createItem(gameData, HAND, ...) -- the second argument is the
    -- inventory handle, i.e. the DESTINATION. The item is created directly
    -- INTO the inventory. We then called addItem(item, ...) on the very same
    -- inventory, registering one engine object in one container twice.
    --
    -- Greg reported this in plain sight and I discounted it as a duplicate-
    -- handler artefact: "its for sure 2 items everytime successful". It was
    -- literal. The log then confirmed it arithmetically -- 11 successful
    -- grants completely filled a pack, which 11 items cannot do but 22 can,
    -- and the pack reported hasRoomForItem=false on grant 8 of 11.
    --
    -- Double-registration corrupts the inventory's internal layout, which is
    -- why the CHARACTER broke rather than just the item list: no move orders,
    -- inventory refusing to open, stats screen flashing shut. Neither call
    -- ever returned an error, so nothing surfaced -- both "succeeded".
    --
    -- Previous theories, both now dead: XP writes (freeze reproduced with XP
    -- off) and drop-into-water (dropOnFail is false now, and the log shows a
    -- clean refusal at grant 8 with no mint at all -- the room check did its
    -- job and the character broke anyway).
    --
    -- createItem placed the item. Do not place it again.
    -- ####################################################################
    if not ADD_AFTER_CREATE then
        return true, ITEM_NAMES[itemId] or itemId
    end

    -- Retained behind a flag ONLY so this is one command to reverse if items
    -- stop appearing: Fishing.setAddAfterCreate(true).
    -- addItem(item, quantity, dropOnFail, destroyOnFail). dropOnFail stays
    -- FALSE -- a fishing character stands in water, and asking the engine to
    -- place a world object there is its own hazard.
    local okAdd, res = pcall(function() return inv:addItem(item, 1, false, true) end)
    if okAdd and res then
        return true, ITEM_NAMES[itemId] or itemId
    end
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
local ALLOW_XP = true

-- ---------------------------------------------------------------------------
-- CAST CAPTIONS
-- ---------------------------------------------------------------------------
-- Greg wants the bar to be funny. Kenshi's own voice is deadpan misery, so
-- these lean bored and faintly disgusted rather than jokey.
-- "smells like dogwater" is Greg's; more of his are expected -- add them here,
-- this list is meant to grow.
local CAPTIONS = {
    "Fishing...",
    "smells like dogwater",          -- Greg
    "Definitely a fish this time",
    "Something touched it",
    "That was a boot",
    "Contemplating the river",
    "Still nothing",
    "The water is not cooperating",
    "I've caught mudcrabs more fierce.",   -- Greg (shortened: the long form
                                          -- outlived its phase on the bar)
    "Ah! A gift from the sea.",                         -- Greg
}

local function pickCaption()
    return CAPTIONS[math.random(#CAPTIONS)] or "Fishing..."
end

-- How far above the fisher's position the bar floats. Tunable from one place
-- because the correct value -- and even which axis is "up" in Kenshi -- is not
-- yet confirmed. Fishing.setBarHeight(n) adjusts it live.
local BAR_HEIGHT = 12.0

-- ---------------------------------------------------------------------------
-- Fishing.unstick() -- try to recover a character whose GUI has locked up
-- ---------------------------------------------------------------------------
-- The recurring #21/#37 symptom is a character that will not take orders, an
-- inventory that will not open, and a stats screen that flashes shut -- while
-- the world keeps running. That reads much more like a WEDGED GUI than a
-- corrupted character, and ForgottenGUI exposes exactly the levers to test it:
--     closeAllInventories() / closeAllCharacterStatsWindows() / closeAllWindows()
--
-- If this recovers a frozen character, the freeze is a stuck window rather than
-- data corruption -- which would be very good news, and would redirect #37
-- entirely. If it does nothing, we have cheaply ruled the theory out.
--
-- Read-ish and reversible: these only close windows the player can reopen.
function Fishing.unstick()
    local okG, gui = pcall(function() return getForgottenGUI() end)
    if not okG or not gui then
        log("unstick: getForgottenGUI() unavailable")
        return false
    end
    for _, m in ipairs({ "closeAllInventories", "closeAllCharacterStatsWindows",
                         "closeTradeWindow", "closeAllWindows" }) do
        local ok, err = pcall(function() gui[m](gui) end)
        log(("  %-32s -> %s"):format(m, ok and "ok" or ("error: " .. tostring(err))))
    end
    log("unstick: done -- try clicking the character now")
    return true
end

-- Fishing.probeBar() -- can we show a real floating progress bar?
--
-- Greg wants the mining/ore-style bar on a cast: "i have no idea, i just press g
-- endlessly." The API exists in the bindings:
--     ForgottenGUI:createFloatingProgressBar() -> FloatingProgressBar
--     FloatingProgressBar:setProgress(number) / :setCaption(string) / :update()
-- What is NOT documented is how to obtain the ForgottenGUI instance -- no global
-- returns one. So this PROBES rather than assuming, and reports what it finds.
--
-- Deliberately a manual command, not wired into the cast. The bindings docs have
-- been wrong ~29 times, and calling an unverified engine surface 100x/sec inside
-- the tick is exactly how the earlier hard crashes happened. Verify first, wire
-- second.
function Fishing.probeBar()
    log("=== progress-bar probe ===")
    local found = {}
    for _, name in ipairs({ "getForgottenGUI", "getGUI", "getGui", "getScreen",
                            "getMainGUI", "getInterface", "getPlayerInterface" }) do
        local ok, v = pcall(function() return _G[name] end)
        if ok and type(v) == "function" then
            found[#found + 1] = name
            local okc, res = pcall(v)
            log(("  %-22s callable -> %s"):format(name, okc and type(res) or "ERROR"))
        end
    end
    if #found == 0 then log("  no GUI accessor global found") end

    -- Direct construction is the other candidate: the type has a _CONSTRUCTOR.
    local okT, T = pcall(function() return _G["FloatingProgressBar"] end)
    log("  FloatingProgressBar global: " .. (okT and type(T) or "ERROR"))
    if okT and type(T) == "table" then
        local keys = {}
        for k in pairs(T) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        log("    keys: " .. (table.concat(keys, ", "):sub(1, 200)))
    end
    log("=== end probe (nothing was drawn) ===")
end

-- ---------------------------------------------------------------------------
-- Fishing.testBar() -- create ONE real progress bar and drive it by hand
-- ---------------------------------------------------------------------------
-- The probe confirmed the route: getForgottenGUI() -> userdata, and
-- ForgottenGUI:createFloatingProgressBar() -> FloatingProgressBar with
-- setCaption / setProgress / update.
--
-- Still NOT wired into the cast, deliberately. Two unknowns remain that only a
-- live look can answer, and both matter before this runs 100x/sec in the tick:
--   1. WHERE does it draw? createFloatingProgressBar takes no position and no
--      character, unlike createFloatingImage(image, top, left, w, h, layer).
--   2. Does it EVER go away? The type has a _DESTRUCTOR but ForgottenGUI
--      exposes no remove/hide, so a bar per cast could accumulate forever.
--
-- One bar is created and cached, so repeat calls reuse it rather than leaking.
-- Log-as-cursor on every step: a hard freeze names the call that caused it.
-- BAR RANGE IS 0..1000, NOT 0..1. Read straight from Kenshi's own layout,
-- data/gui/layout/Kenshi_ProgressBarPanel.layout:
--     <Widget type="ProgressBar" name="ProgressBar">
--         <Property key="Range" value="1000"/>
-- which also matches the binding's field type (`progress | integer`).
--
-- The first test passed 0.5 -- five hundredths of one percent of the bar, i.e.
-- indistinguishable from empty. That layout file is the same widget the mining
-- bar uses, so it is the authority here rather than my assumption of a 0..1
-- fraction.
local BAR_RANGE = 1000

function Fishing.testBar(pct)
    -- Accept either convention: <=1 is treated as a fraction and scaled up, so
    -- testBar(0.5) and testBar(500) both mean half.
    pct = tonumber(pct) or 0.5
    if pct <= 1 then pct = pct * BAR_RANGE end

    if not Fishing._bar then
        log("testBar: getForgottenGUI()")
        local okG, gui = pcall(function() return getForgottenGUI() end)
        if not okG or not gui then log("  FAILED: " .. tostring(gui)) return false end

        log("testBar: gui:createFloatingProgressBar()")
        local okB, bar = pcall(function() return gui:createFloatingProgressBar() end)
        if not okB or not bar then log("  FAILED: " .. tostring(bar)) return false end
        Fishing._bar = bar
        log("  created, type=" .. type(bar))
    else
        log("testBar: reusing cached bar (not creating a second one)")
    end

    local bar = Fishing._bar
    log("testBar: setCaption()")
    local okC, e1 = pcall(function() bar:setCaption(pickCaption()) end)
    if not okC then log("  setCaption error: " .. tostring(e1)) end

    log(("testBar: setProgress(%d)  [range 0..%d]"):format(pct, BAR_RANGE))
    local okP, e2 = pcall(function() bar:setProgress(pct / BAR_RANGE) end)
    pcall(function() bar.progress = math.floor(pct) end)
    if not okP then log("  setProgress error: " .. tostring(e2)) end

    log("testBar: update()")
    local okU, e3 = pcall(function() bar:update() end)
    if not okU then log("  update error: " .. tostring(e3)) end

    -- ATTACH IT TO THE CHARACTER -- this is the "where the mining bar sits"
    -- question, answered from the API rather than guessed.
    --
    -- FloatingProgressBar and ScreenLabel share a header (kenshi/gui/ScreenLabel.h),
    -- and ScreenLabel carries exactly the fields Kenshi's own world-space bars
    -- need:
    --     trackingHandle (hand)     -- the object the label follows
    --     trackingOffset (Vector3)  -- how high above it to float
    -- What is NOT known is whether the Lua binding exposes those INHERITED
    -- fields on FloatingProgressBar, since its own documented field list is just
    -- caption / progress / bar. So introspect first and report, rather than
    -- assigning blind into a userdata.
    -- MEASURED (live run): FloatingProgressBar does NOT inherit ScreenLabel's
    -- Lua surface, despite sharing its C++ header.
    --     trackingHandle  nil        no auto-follow
    --     trackingOffset  nil
    --     destroy         nil        no teardown
    --     destroyed       nil
    --     setPosition     function   <- but we can place it ourselves
    -- So the bar cannot be attached to a character and cannot be destroyed.
    -- It CAN be positioned, and the tick already reads the fisher's position
    -- every frame, so we drive it manually instead. Nothing was visible on the
    -- first run because an unpositioned bar sits at world origin.
    log("testBar: fields present on this bar:")
    for _, f in ipairs({ "setPosition", "setVisible", "visible", "setCaption",
                         "progress", "caption", "update" }) do
        local okF, v = pcall(function() return bar[f] end)
        log(("    %-16s %s"):format(f, okF and type(v) or "ERROR"))
    end

    -- Put it ON the fisher, using the same position read the cast anchor uses.
    local okSel, character = pcall(function() return getSelectedCharacter() end)
    if okSel and character then
        local p = readPos(character)
        if p then
            -- Y-up is assumed; if the bar lands at the character's feet or
            -- inside them, this offset is the knob (and tells us which axis
            -- is up, which nothing so far has confirmed).
            local target = { x = p.x, y = (p.y or 0) + BAR_HEIGHT, z = p.z }
            local okP, e = pcall(function() bar:setPosition(target) end)
            log(("testBar: setPosition(%.1f, %.1f, %.1f) -> %s")
                :format(target.x, target.y, target.z, okP and "ok" or tostring(e)))
            pcall(function() bar:update() end)
        else
            log("testBar: could not read character position")
        end
    end

    log("testBar: done -- LOOK AT THE SCREEN. Is it on the character now?")
    return true
end

-- ---------------------------------------------------------------------------
-- PER-CHARACTER CAST BAR
-- ---------------------------------------------------------------------------
-- Greg: "without lua up its hard to know if im fishing or not." That is the
-- whole job here -- say WHO is doing WHAT and HOW FAR ALONG. No inventory slot,
-- no output container (see #40); just the character's current action.
--
-- ONE BAR PER CHARACTER, CREATED ONCE, REUSED FOREVER. This is forced, not
-- stylistic: the live probe showed FloatingProgressBar exposes no destroy() and
-- no `destroyed` flag, so a bar made per cast could never be reclaimed. Bars are
-- cached on the character's state and parked out of sight when idle.
--
-- Updated at ~10Hz rather than every tick. onCharsUpdate fires ~100/sec, and a
-- 5-second bar does not need 500 updates -- 50 is already smoother than the eye
-- resolves, and this code sits in the hot path for every fisher at once.
local BAR_UPDATE_EVERY = 10
-- Far off on EVERY axis. The old park spot was {0, -10000, 0}, which is the map
-- origin once the Y is ignored -- i.e. dead centre of the world.
local BAR_PARK_FAR = 9000000

local function barFor(s)
    if s.bar ~= nil then return s.bar or nil end
    local okG, gui = pcall(function() return getForgottenGUI() end)
    if not okG or not gui then s.bar = false return nil end
    local okB, bar = pcall(function() return gui:createFloatingProgressBar() end)
    if not okB or not bar then s.bar = false return nil end
    s.bar = bar
    return bar
end

-- Place the bar on the fisher and set its fill. frac is 0..1; the widget's own
-- range is 0..1000 (Kenshi_ProgressBarPanel.layout).
local function barUpdate(s, character, frac, caption)
    if not CFG.showBar then return end
    local bar = barFor(s)
    if not bar then return end
    local p = readPos(character)
    if p then
        -- ONE-TIME DIAGNOSTIC. Which axis is "up" in Kenshi is still unconfirmed,
        -- and BAR_HEIGHT is applied to Y on that assumption. Logging the raw
        -- position once lets it be checked against the terrainH already printed
        -- in the SURVEY line: if y is close to terrainH then Y is up and the
        -- offset is correct; if z matches instead, the offset is on the wrong
        -- axis and the bar is floating sideways rather than overhead.
        -- One log line, not per-frame spam.
        if not Fishing._barPosLogged then
            Fishing._barPosLogged = true
            -- %s not %f: this threw once with "number expected, got nil" and took
            -- the whole onCharsUpdate handler down for that frame. A DIAGNOSTIC
            -- must never be able to kill the tick it is diagnosing.
            log(("bar position basis: x=%s y=%s z=%s  (+%s on Y)"):format(
                tostring(p.x), tostring(p.y), tostring(p.z), tostring(BAR_HEIGHT)))
        end
        pcall(function()
            bar:setPosition({ x = p.x, y = (p.y or 0) + BAR_HEIGHT, z = p.z })
        end)
    end
    if caption then pcall(function() bar:setCaption(caption) end) end

    -- THE FILL DID NOT MOVE with setProgress() alone, though the bar itself
    -- appeared and the caption worked. FloatingProgressBar exposes `progress`
    -- as an RW FIELD as well as a setProgress() method, and the two are not
    -- necessarily the same path to the underlying MyGUI RangePosition -- one may
    -- set a member the repaint never reads.
    --
    -- So drive both, then repaint. All pcall-wrapped: whichever is not the real
    -- channel simply does nothing, and the widget cannot be left half-updated.
    -- THE TWO CHANNELS TAKE DIFFERENT SCALES. Observed live: the bar jumped to
    -- 100% immediately after a cast began and read blank when it ended.
    --
    -- Blank at the end is barHide writing 0, so 0 lands correctly. Full at the
    -- start is the first tick update: at ~2% progress we were sending
    -- floor(0.02 * 1000) = 20 into setProgress(). If that method wants a 0..1
    -- FRACTION, then anything above 1 clamps to full -- which is exactly the
    -- "refreshes rather than loads" behaviour, a bar snapping between 0 and 100.
    --
    -- The FIELD is 0..1000 (integer, mirroring the widget's RangePosition of
    -- Range=1000 in Kenshi_ProgressBarPanel.layout). The METHOD normalises.
    -- Feed each the scale it wants instead of one value to both.
    pcall(function() bar.progress = math.floor(frac * BAR_RANGE) end)  -- 0..1000
    pcall(function() bar:setProgress(frac) end)                        -- 0..1
    pcall(function() bar.needUpdate = true end)   -- ScreenLabelInterface repaint flag
    pcall(function() bar:update() end)

    -- One readback, mid-cast, to see whether the value is landing at all. If it
    -- reads back what we wrote and the bar still looks empty, the problem is the
    -- repaint rather than the value -- a different fix entirely.
    if not Fishing._barProgLogged and frac > 0.3 then
        Fishing._barProgLogged = true
        local okR, got = pcall(function() return bar.progress end)
        log(("bar progress: wrote %d (range %d) -> reads back %s")
            :format(v, BAR_RANGE, okR and tostring(got) or "ERROR"))
    end
end

local function barHide(s)
    local bar = s.bar
    if not bar then return end
    -- PARKING AT x=0,z=0 PUT THE BAR AT MAP CENTRE.
    -- It was parked at {0, -10000, 0} on the assumption that a huge negative Y
    -- would bury it. Greg found a bar stranded in the middle of the map long
    -- after walking away, so the Y is clamped or ignored and only X/Z were
    -- honoured -- leaving it at the world origin, which is the single worst
    -- place to put something meant to be invisible.
    --
    -- There is no setVisible on this type, so hiding has to be done by making it
    -- both empty AND remote: blank the caption, zero the fill, and move it far
    -- off on every axis rather than to an origin-adjacent point.
    pcall(function() bar:setCaption("") end)
    pcall(function() bar.progress = 0 end)
    pcall(function() bar:setProgress(0) end)
    pcall(function() bar:setPosition({ x = BAR_PARK_FAR, y = BAR_PARK_FAR, z = BAR_PARK_FAR }) end)
    pcall(function() bar:update() end)
end

-- Fishing.setBar(false) -- kill switch if the bar ever misbehaves in the tick.
function Fishing.setBar(on)
    CFG.showBar = (on == true)
    log("cast bar -> " .. tostring(CFG.showBar))
    return CFG.showBar
end

-- ---------------------------------------------------------------------------
-- THE CATCH BAG
-- ---------------------------------------------------------------------------
-- Kenshi's own gathering professions never stream product into a working
-- character's pack -- it lands in a separate container and the player collects
-- it. Greg's read is that this is an engine law rather than a UI choice, and the
-- evidence supports him: the freeze survived every cap, and the last occurrence
-- needed only eleven grants.
--
-- The bag is plain Lua state. Fishing performs no engine writes; collecting is
-- one deliberate, bounded, player-initiated action.

-- Fishing.bag() -- show what the selected character has caught but not collected.
function Fishing.bag()
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then log("bag: select a character first") return end
    local okN, name = pcall(function() return c:getName() end)
    name = (okN and name) or "?"
    local s = stateFor(name)
    if not s.bag or (s.bagCount or 0) == 0 then
        log(name .. ": catch bag is empty")
        return 0
    end
    log(("%s: catch bag (%d)"):format(name, s.bagCount))
    for id, n in pairs(s.bag) do
        log(("    %-22s x%d"):format(tostring(ITEM_NAMES[id] or id), n))
    end
    return s.bagCount
end

-- Fishing.showBag() -- put the catch bag ON SCREEN (J).
--
-- NOT a real menu, and it cannot be one. Every GUI construction call in
-- KenshiLua returns opaque `lightuserdata` and there is no Widget binding, so a
-- panel we create can never be populated -- and nothing exposes Kenshi's own
-- container UI. `createScreenLabelD(text, time)` is the one text surface
-- available: fire-and-forget, self-expiring, no handle to update. A clickable
-- transfer window needs C++ (see #42).
function Fishing.showBag()
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then return end
    local okN, name = pcall(function() return c:getName() end)
    name = (okN and name) or "?"
    local s = stateFor(name)

    local lines
    if not s.bag or (s.bagCount or 0) == 0 then
        lines = name .. " -- catch bag empty"
    else
        local parts = { ("%s -- CATCH BAG (%d)"):format(name, s.bagCount) }
        for id, n in pairs(s.bag) do
            parts[#parts + 1] = ("  %s x%d"):format(tostring(ITEM_NAMES[id] or id), n)
        end
        parts[#parts + 1] = "  [H] collect into inventory"
        lines = table.concat(parts, "\n")
    end

    local okG, gui = pcall(function() return getForgottenGUI() end)
    if not okG or not gui then log(lines) return end
    local okL = pcall(function() gui:createScreenLabelD(lines, CFG.bagShowSecs) end)
    -- Always log too: if the label does not render, the information is not lost.
    log(lines)
    if not okL then log("(screen label unavailable -- log only)") end
end

-- Fishing.collect() -- move the catch bag into the character's inventory.
--
-- The ONLY place fishing writes to an inventory, and only when the player asks.
-- Stops at the first refusal and keeps the remainder banked, so a full pack
-- costs one refused grant instead of one every five seconds forever.
function Fishing.collect()
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then log("collect: select a character first") return end
    local okN, name = pcall(function() return c:getName() end)
    name = (okN and name) or "?"
    local s = stateFor(name)

    if not s.bag or (s.bagCount or 0) == 0 then
        log(name .. ": nothing to collect")
        return 0
    end

    local moved, stoppedOn = 0, nil
    for id, n in pairs(s.bag) do
        for _ = 1, n do
            local granted, how = tryGrantItem(c, id)
            if not granted then stoppedOn = how break end
            s.bag[id] = s.bag[id] - 1
            s.bagCount = s.bagCount - 1
            moved = moved + 1
        end
        if s.bag[id] == 0 then s.bag[id] = nil end
        if stoppedOn then break end
    end

    if stoppedOn then
        log(("%s: collected %d, %d still banked -- %s")
            :format(name, moved, s.bagCount, tostring(stoppedOn)))
    else
        log(("%s: collected %d item(s); catch bag empty"):format(name, moved))
    end
    return moved
end

-- Fishing.setBarHeight(3) -- raise or lower the bar, live, while looking at it.
-- Beats redeploying to guess a world-unit offset.
function Fishing.setBarHeight(n)
    BAR_HEIGHT = tonumber(n) or 2.0
    log("bar height -> " .. tostring(BAR_HEIGHT))
    return BAR_HEIGHT
end

-- Fishing.clearBar() -- hide the test bar.
--
-- CORRECTION: I claimed destroy() existed because ScreenLabel has it. The live
-- run says FloatingProgressBar does NOT expose it -- `destroy` reads nil, and
-- calling it errors. So there is no teardown, which means the design rule is
-- ONE bar per character, reused forever, never one per cast.
--
-- Hiding therefore has to be done by other means: setVisible if the binding has
-- it, otherwise park the bar far below the world where it cannot be seen.
function Fishing.clearBar()
    local bar = Fishing._bar
    if not bar then log("clearBar: no bar") return end
    if type(bar.setVisible) == "function" then
        local ok, err = pcall(function() bar:setVisible(false) end)
        log("clearBar: setVisible(false) -> " .. (ok and "ok" or tostring(err)))
    else
        local ok = pcall(function() bar:setPosition({ x = 0, y = -10000, z = 0 }) end)
        log("clearBar: no setVisible; parked below world -> " .. (ok and "ok" or "failed"))
    end
    pcall(function() bar:update() end)
end

-- Fishing.setAddAfterCreate(true) -- reverse the double-registration fix live,
-- for the single case where items stop appearing in the inventory at all.
function Fishing.setAddAfterCreate(on)
    ADD_AFTER_CREATE = (on == true)
    log("addItem-after-createItem -> " .. tostring(ADD_AFTER_CREATE))
    return ADD_AFTER_CREATE
end

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
    -- Pack fullness is checked BEFORE the 5-second cast, not after it, so the
    -- refusal is immediate feedback rather than a wasted wait ending in nothing.
    -- canFish stays purely about water state; this is a separate gate.
    -- COUNT CAP FIRST. This is the gate that must fire, because it is the one
    -- that keeps us away from a saturated grid entirely. hasRoomForItem stays
    -- below it as a backstop, but by then we are already at the boundary that
    -- is under suspicion for the freeze.
    -- WHILE BANKING, SKIP EVERY INVENTORY GATE. The catch goes into a Lua table,
    -- so there is nothing to have room for -- and the entire point is that the
    -- loop performs no inventory calls whatsoever. Fullness is the collect
    -- step's problem, once, when the player asks for it.
    if not CFG.bankCatches then
    -- CHEAP GATE FIRST, and it must not touch the grid. A player mashing G at a
    -- full pack previously fired one hasRoomForItem per press.
    if Fishing.packKnownFull(s, character) then
        if not s.fullLogged then
            s.fullLogged = true
            log(name .. ": PACK FULL -- empty some items, then press G again")
        end
        return
    end
    s.fullLogged = nil
    if not Fishing.underCatchCap(s, character) then
        log(name .. ": PACK FULL (catch cap) -- empty the pack, then press G again")
        return
    end
    if not Fishing.hasPackHeadroom(character) then
        Fishing.notePackFull(s, character)   -- remember, so we never re-probe
        log(name .. ": PACK FULL -- make space before fishing (issue #21 guard)")
        return
    end
    end   -- if not CFG.bankCatches
    s.casting, s.elapsed = true, 0
    -- HOLD THE CASTER. The tick used to re-resolve the fisher through
    -- getSelectedCharacter() every frame and skip any cast whose name did not
    -- match the current selection -- which made squad fishing structurally
    -- impossible: a second fisher's cast froze the instant you clicked someone
    -- else. Each cast now carries its own character, so selection is a UI
    -- concern only and N fishers run independently.
    --
    -- The reference is held for one cast (~5s) and re-validated every tick
    -- before use, so a character that dies or unloads mid-cast drops the cast
    -- instead of being dereferenced.
    s.character = character
    -- One caption per cast, held for the whole cast rather than re-rolled on
    -- every bar update -- a caption that flickered 10x/sec would be unreadable.
    -- Caption carries the banked count, because with catches going to a Lua bag
    -- there is otherwise NOTHING on screen telling the player they are
    -- accumulating anything -- the inventory stays empty until they collect.
    s.caption = pickCaption()
    local held = s.bagCount or 0
    barUpdate(s, character, 0,
        held > 0 and (s.caption .. "   [" .. held .. " to collect - H]") or s.caption)
    -- Anchor the cast to a spot. Moving away cancels it (see the tick handler):
    -- fishing is a deliberate act you stand still for, not something done at a jog.
    s.anchor = readPos(character)
    log(name .. ": cast! (" .. why .. ") ... hold still " .. CFG.castSeconds .. "s")
end

local function finishCast(character, name)
    local s = stateFor(name)
    s.casting, s.elapsed = false, 0
    -- Park the bar the moment the cast ends. In auto it reappears immediately
    -- on the next cast; the brief gap is the visual beat between casts.
    barHide(s)

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

    -- BANKED PATH: no engine call at all. The catch is a number in a Lua table
    -- until the player collects it. This is the whole point -- the fishing loop
    -- must not touch the character's inventory.
    if CFG.bankCatches then
        s.bag = s.bag or {}
        s.bag[itemId] = (s.bag[itemId] or 0) + 1
        s.bagCount = (s.bagCount or 0) + 1
        log(("%s: CAUGHT %s%s | banked (%d in catch bag) | totals fish=%d junk=%d")
            :format(name, itemId, isGarbage and " (junk)" or "",
                    s.bagCount, s.caught, s.garbage))
        return
    end

    local granted, how = tryGrantItem(character, itemId)
    log(("%s: CAUGHT %s%s | grant: %s (%s) | totals fish=%d junk=%d")
        :format(name, itemId, isGarbage and " (junk)" or "",
                granted and "OK" or "FAILED", how, s.caught, s.garbage))

    -- GROUND TRUTH BEATS ANY PROBE. A predictive gate can be wrong -- the
    -- Straw Hat probe was, and auto re-cast eighteen times into a pack that
    -- refused every single item. A grant that ACTUALLY failed for lack of room
    -- is not a prediction, it is the pack itself answering.
    --
    -- Belt and braces on purpose: the headroom gate should stop us before we
    -- ever get here, but when it does not, this cannot miss.
    if not granted and type(how) == "string" and how:find("no room", 1, true) then
        s.auto = false
        Fishing.notePackFull(s, character)
        log(name .. ": auto-fish STOPPED -- pack full (grant refused)")
    end
end

-- AUTO-FISH re-arm. Kenshi's idiom is "give the order once and walk away", not
-- "press the key once per action" -- Greg's words were "i just press g
-- endlessly". A character told to fish keeps fishing until something real stops
-- them: pack full, walked away, water gone, or told to stop.
--
-- Placed after finishCast and called from the TICK rather than from inside
-- finishCast, so it can see beginCast (declared above it) without a forward
-- declaration -- the nil-upvalue trap that already cost this file one debugging
-- session when FISH_PREFERENCE was used above its own declaration.
local function rearmIfAuto(character, name)
    local s = stateFor(name)
    if not s.auto or s.casting then return end
    -- Re-check the same two gates the key press checks, so auto stops for
    -- exactly the reasons a manual cast would refuse -- no special cases.
    local can, why = Fishing.canFish(character)
    if not can then
        s.auto = false
        log(name .. ": auto-fish STOPPED -- " .. why)
        return
    end
    if not CFG.bankCatches then
    if Fishing.packKnownFull(s, character) then
        s.auto = false
        log(name .. ": auto-fish STOPPED -- pack full")
        return
    end
    if not Fishing.underCatchCap(s, character) then
        s.auto = false
        log(name .. ": auto-fish STOPPED -- catch cap reached (pack not saturated)")
        return
    end
    if not Fishing.hasPackHeadroom(character) then
        Fishing.notePackFull(s, character)
        s.auto = false
        log(name .. ": auto-fish STOPPED -- pack full")
        return
    end
    end   -- if not CFG.bankCatches
    beginCast(character, name)
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

        -- H: collect the catch bag into the selected character's inventory.
        -- This is the ONLY inventory write fishing performs, and it happens
        -- because the player asked for it.
        if kc == CFG.collectKey then
            Fishing.collect()
            return
        end

        -- J: show the catch bag on screen.
        if kc == CFG.bagKey then
            Fishing.showBag()
            return
        end

        if kc ~= CFG.fishKey then
            -- Confirm the collect scancode if H turns out not to be 35. Logged
            -- once per key so normal play does not spam the log.
            Fishing._seenKeys = Fishing._seenKeys or {}
            if kc and not Fishing._seenKeys[kc] then
                Fishing._seenKeys[kc] = true
                log("key " .. tostring(kc) .. " (G=" .. CFG.fishKey .. ", collect=" .. CFG.collectKey .. ")")
            end
            return
        end
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

        -- G IS A TOGGLE, not a single cast. Greg: "i just press g endlessly."
        -- Kenshi's idiom is to give an order once and let the character work
        -- until something stops them, so G means "fish / stop fishing" and the
        -- character repeats on their own.
        --
        -- Per-CHARACTER, so a squad is armed by selecting each in turn and
        -- pressing G: they then fish in parallel, because the tick no longer
        -- depends on who is selected.
        local s = stateFor(name)
        if s.auto then
            s.auto = false
            s.casting, s.elapsed, s.anchor = false, 0, nil
            barHide(s)
            -- G ALSO COLLECTS. Greg: "i dont want it to be a seperate button
            -- that is to much for the player. what about on g both happen."
            --
            -- Stopping is the right moment: the player has finished, and it is
            -- still ONE bounded, player-initiated write rather than a write
            -- every five seconds -- which is the rule that fixed the freeze.
            -- H remains as an explicit collect for mid-run top-ups.
            local n = s.bagCount or 0
            if n > 0 then
                log(("%s: auto-fish OFF -- collecting %d"):format(name, n))
                Fishing.collect()
            else
                log(name .. ": auto-fish OFF")
            end
            return
        end
        -- ...and G collects on the way IN as well, not only on the way out.
        -- Auto can stop for reasons the player did not choose (walked off the
        -- anchor, waded too deep, attacked), which would otherwise strand the
        -- bag until they pressed G twice. Collecting here means one G always
        -- banks what is owed before starting again.
        --
        -- Safe against mashing: once the bag is empty this is a no-op, so
        -- repeated presses cannot repeat the write.
        if (s.bagCount or 0) > 0 then
            log(("%s: collecting %d before casting"):format(name, s.bagCount))
            Fishing.collect()
        end

        s.auto = true
        -- RE-BASELINE the catch cap on every manual start. Pressing G is the
        -- player saying "go again", which is exactly when they have just made
        -- room. Without this, one full pack would disable fishing permanently.
        s.baseItems = (not CFG.bankCatches) and Fishing.itemCount(character) or nil
        log(("%s: auto-fish ON  (pack has %s items; stopping after %d catches)")
            :format(name, tostring(s.baseItems), CFG.maxCatchesPerLoad))
        beginCast(character, name)
        -- beginCast refuses on dry land or a full pack and says why. Do not
        -- leave auto armed after a refusal, or the character would silently
        -- start fishing later when conditions happened to change.
        if not s.casting then
            s.auto = false
            log(name .. ": auto-fish OFF (could not start)")
        end
    end)
    log("input hook armed -- select a character, WADE into shallow water, press G to start/stop fishing")

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

                -- The caster is whoever STARTED this cast, not whoever happens
                -- to be selected. Selection is a UI concern; casts are not.
                --
                -- This used to call getSelectedCharacter() and skip any cast
                -- whose name did not match, which meant only one character could
                -- ever fish -- clicking a squadmate silently froze everyone
                -- else's cast until it hit the timeout valve.
                --
                -- Re-validate the held reference before touching it: a cheap
                -- getName() proves the character is still live. If that fails,
                -- drop the cast rather than dereference something unloaded.
                local character = s.character
                local ok = false
                if character then
                    local okN = pcall(function() return character:getName() end)
                    ok = okN
                end

                -- SAFETY VALVE: a cast may never hang. If it somehow outlives
                -- twice its own duration, drop it rather than wedge the state.
                if s.elapsed > target * 2 then
                    s.casting, s.elapsed, s.anchor = false, 0, nil
                    barHide(s)
                    s.auto = false   -- a stuck cast must not silently re-arm
                    log(name .. ": cast timed out (stuck) -- reset")
                elseif not ok or not character then
                    s.casting, s.anchor, s.character = false, nil, nil
                    barHide(s)   -- a dead/unloaded fisher must not leave a bar behind
                    s.auto = false
                else
                    -- STANDSTILL: drifting off the anchor cancels the cast.
                    if s.anchor then
                        local now = readPos(character)
                        local d2 = now and distSq(now, s.anchor) or 0
                        if now and d2 > CFG.moveToleranceSq then
                            s.casting, s.elapsed, s.anchor = false, 0, nil
                    barHide(s)
                            -- Walking away CANCELS auto-fishing, the same way a
                            -- Kenshi job drops when you order the character
                            -- somewhere else. Greg fishes under attack ("dust
                            -- bandits, bone dogs"), so fleeing must not leave an
                            -- invisible loop armed that re-casts on arrival.
                            s.auto = false
                            -- Report the ACTUAL drift so the tolerance is tuned
                            -- from measurement rather than my guess at Kenshi's
                            -- world-unit scale.
                            log(("%s: cast broken -- moved %.1f units (tolerance %.1f)")
                                :format(name, math.sqrt(d2), math.sqrt(CFG.moveToleranceSq)))
                        end
                    end
                    -- Drive the bar at ~10Hz. Throttled because onCharsUpdate
                    -- fires ~100/sec and this runs for every fisher at once; a
                    -- 5s bar does not need 500 updates.
                    if s.casting and (s.elapsed % BAR_UPDATE_EVERY == 0) then
                        barUpdate(s, character, s.elapsed / target, nil)
                    end
                    -- Water can also change underfoot mid-cast (waded out too deep).
                    if s.casting then
                        local can, why = Fishing.canFish(character)
                        if not can then
                            s.casting, s.elapsed, s.anchor = false, 0, nil
                    barHide(s)
                            s.auto = false   -- waded out of fishable water
                            log(name .. ": cast broken -- " .. why)
                        elseif s.elapsed >= target then
                            finishCast(character, name)
                            -- Re-arm HERE rather than inside finishCast, so the
                            -- catch is fully resolved and logged before the next
                            -- cast starts. rearmIfAuto is a no-op unless auto is
                            -- on, so the manual path is unchanged.
                            rearmIfAuto(character, name)
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
