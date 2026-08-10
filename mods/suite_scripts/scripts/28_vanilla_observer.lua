-- ============================================================================
-- VANILLA OBSERVER  (manual only -- lives in scripts/, NOT scripts/init/)
--
-- Greg: "the game is mostly a mystery under the hood, we only barely know
-- what's in it." This is the bulk-scrape tool for that -- register safe
-- listeners across every roadmap-relevant vanilla system at once (slavery,
-- theft, dialogue, trade, jobs, buildings, XP) and log everything the
-- ENGINE'S OWN AI does during ordinary play, near ordinary content (a slave
-- camp is a great choice -- slaves, guards, crime, and trade all in one
-- place). No guessing at what vanilla does -- read it off the log.
--
-- WHY THIS IS SAFE TO RUN IN BULK
-- third_party/KenshiLua/docs/CallbacksReference.md (found 2026-08-10,
-- auto-generated from the actual compiled source -- src/Callbacks.h,
-- src/Hooks.cpp, so every event below is REAL, not a doc guess) documents
-- two callback shapes:
--   1. NOTIFICATION -- fires when something already happened. Returning
--      anything from our handler cannot change engine behavior at all.
--   2. OVERRIDE -- fires when the engine is ABOUT TO calculate a value
--      (item price, dialogue condition, fencing chance...). The engine uses
--      OUR return value INSTEAD of its own ONLY if we return a non-nil value
--      matching the expected type. Every handler below logs and returns
--      NOTHING (no `return` statement at all -- Lua functions with no
--      explicit return already return nil), so every override callback here
--      is a pure observer too: the engine's own calculation always wins,
--      unchanged. This file cannot alter gameplay, only watch it.
--
-- WHAT "SAFE" DID NOT COVER, FOUND LIVE 2026-08-10: a handler FIRING safely
-- is a different claim from REGISTERING it being safe. The first version of
-- Observer.start() crashed the game with zero log output between it starting
-- and the process dying -- pcall around registerHandler is worthless against
-- a native crash (KENSHI-ENGINE-NOTES.md's own rule 1, now hit twice this
-- project). Every registerHandler call below is now preceded by its own log
-- line, so a repeat crash names the exact event instead of leaving all 38 as
-- suspects. See QUARANTINE below Observer.stop().
--
-- CONTRACT
--     Observer.start()          -> registers every non-quarantined hook,
--                                   logging each registration attempt BEFORE
--                                   it happens
--     Observer.startOne(name)   -> register exactly ONE event, for bisecting
--                                   a crash without risking the rest
--     Observer.stop()           -> unregisters all of them
--     Observer.list()           -> prints what is being watched, by tag
--
--   dofile("mods/KenshiLua/scripts/28_vanilla_observer.lua")
--   Observer.start()
--   -- go play normally near varied content for a few minutes --
--   Observer.stop()
--   -- then: python tools/readlog.py --tag OBS   (or --tag SLAVE, THEFT, etc.)
-- ============================================================================

local TAG = "[OBS] "
local function log(m) print(TAG .. tostring(m)) end

Observer = Observer or {}
pcall(function() _G.Observer = Observer end)

-- RELOAD SAFETY -- same generation-guard shape as every other handler-owning
-- file in this suite (10_fishing.lua, 27_projector_probe.lua).
if Observer._handlers and type(unregisterHandler) == "function" then
    for _, hid in ipairs(Observer._handlers) do pcall(unregisterHandler, hid) end
end
Observer._handlers = {}

-- ---------------------------------------------------------------------------
-- Generic arg-describer -- works for every event regardless of arg count or
-- type, so this file does not need a hand-written formatter per event. Each
-- value is tostring()'d only (never indexed/called), so this cannot trip a
-- container-typed-member crash the way inspecting a field WOULD.
-- ---------------------------------------------------------------------------
local function describeArgs(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        local v = select(i, ...)
        local ok, s = pcall(tostring, v)
        parts[#parts + 1] = ok and s or "<unprintable>"
    end
    return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- THE WATCH LIST -- curated from CallbacksReference.md's 65 notification +
-- 20 override events, cut down to the ones that actually matter to this
-- project's roadmap (skipped: title-screen/build-mode/squad-management UI
-- plumbing that tells us nothing about how vanilla gameplay works).
--
-- tag groups the output for `readlog.py --tag <TAG>` -- one system's worth
-- of events at a time instead of the whole firehose.
-- ---------------------------------------------------------------------------
local EVENTS = {
    -- JOBS / ALIVE CORE / TOWNS (#28, #33, #34, #46, #49) -- Projector
    -- already covers the addJob/addOrder/addGoal/removeJob family
    -- (27_projector_probe.lua); onPlayerOrderGiven is the one this file
    -- adds on top, for what the PLAYER'S own click-to-order looks like.
    { event = "onPlayerOrderGiven",              tag = "JOBS" },

    -- SLAVERY (#32)
    { event = "onCharacterFactionChanged",       tag = "SLAVE" },
    { event = "onCrimeWitnessed",                tag = "SLAVE" },
    { event = "onLimbAmputated",                 tag = "SLAVE" },   -- candidate signal for "Broken" status
    { event = "onCharacterHitByMelee",           tag = "SLAVE" },
    { event = "onCharacterTakeMoney",             tag = "SLAVE" },   -- confiscation / pay?
    { event = "onCharacterGettingEaten",          tag = "SLAVE" },   -- grim, but real hook -- cannibal factions exist

    -- SHADOW (#31)
    { event = "onPlayerStealCheck",              tag = "SHADOW" },
    { event = "onSmugglingTradeCheck",           tag = "SHADOW" },
    { event = "onGetFencingChance",              tag = "SHADOW" },  -- OVERRIDE, logged read-only
    { event = "onItemStolen",                     tag = "SHADOW" },
    { event = "xpStealth",                        tag = "SHADOW" },
    { event = "xpLockpicking",                    tag = "SHADOW" },

    -- TAVERNS / DIALOGUE (#29)
    { event = "onDialogueCheckCondition",        tag = "TAVERN" },  -- OVERRIDE, logged read-only
    { event = "onDialogueStartConversation",     tag = "TAVERN" },  -- OVERRIDE, logged read-only
    { event = "onDialogueWindowShow",             tag = "TAVERN" },
    { event = "onDialogueSay",                    tag = "TAVERN" },
    { event = "onDialogueDoActions",              tag = "TAVERN" },
    { event = "onDialogueEndDialogue",            tag = "TAVERN" },

    -- ECONOMY / TOWNS / SHOP RIGHTS (#28, #46, #48, #50)
    { event = "onItemGetValueSingle",            tag = "ECON" },    -- OVERRIDE, logged read-only
    { event = "onBuildingCalculateSaleValue",    tag = "ECON" },    -- OVERRIDE, logged read-only
    { event = "onBuildingIsForSale",              tag = "ECON" },    -- OVERRIDE, direct hit on #50
    { event = "onBuildingIsPublic",               tag = "ECON" },    -- OVERRIDE, logged read-only
    { event = "onBuildingUseCheck",               tag = "ECON" },    -- OVERRIDE, logged read-only
    { event = "onPlatoonIBuyStolenGoods",        tag = "ECON" },    -- OVERRIDE, logged read-only
    { event = "onPlatoonIBuyIllegalGoods",       tag = "ECON" },    -- OVERRIDE, logged read-only

    -- CAMPS / BUILDINGS (#30, #24 docks)
    { event = "onBuildingSetResidentSquad",      tag = "BUILD" },
    { event = "onBuildingAddInternalBuilding",   tag = "BUILD" },

    -- CHARACTER LIFECYCLE (#43 skeleton gear, #44 drones, #45 robot scrap)
    { event = "onCharacterDeath",                tag = "LIFE" },    -- #45 robot scrap trigger candidate
    { event = "onCharacterEat",                   tag = "LIFE" },
    { event = "onCharacterEquip",                 tag = "LIFE" },    -- #43/#44 equip-slot signal
    { event = "onCharacterUnequip",               tag = "LIFE" },
    { event = "onCharacterPickupObject",          tag = "LIFE" },

    -- SKILLS / XP -- #14's onGetStat idea (never built, see #14's status
    -- note) plus every OTHER measured-live-or-not skill event. Fishing only
    -- ever measured 4 stat ids (labouring/swimming/precisionShooting/
    -- perception); this is how Cooking's still-unmeasured id (#18) and any
    -- future trade's stat id get FOUND instead of guessed.
    { event = "onGetStat",                        tag = "SKILL" },   -- OVERRIDE, logged read-only
    { event = "onCharStatsXpStatEvent",           tag = "SKILL" },
    { event = "xpEngineering",                    tag = "SKILL" },
    { event = "xpFirstAid",                       tag = "SKILL" },
    { event = "xpRunning",                        tag = "SKILL" },
}

-- QUARANTINE -- event names that crashed the game DURING REGISTRATION (not
-- during a fired callback -- see the note below). Add here as they are
-- found; Observer.start() skips them.
--
-- FOUND LIVE 2026-08-10: the first version of this function crashed Kenshi
-- with ZERO log output between "Projector observing -- 3 hook(s) armed" and
-- the process dying -- not even a partial "registered N of 38" line, because
-- the only log call was a SUMMARY after the whole loop finished. registerHandler
-- itself was wrapped in pcall, which is worthless here: pcall does not catch
-- a native access violation, the same lesson KENSHI-ENGINE-NOTES.md already
-- states and this project has now hit twice. The loop crashed silently on
-- SOME event in the list, and there was no way to tell which. Fixed below by
-- logging the event name BEFORE each individual registerHandler call --
-- log-as-cursor, applied to REGISTRATION, not just to firing a callback.
local QUARANTINE = {
    -- FOUND LIVE 2026-08-10 (second incident): all 38 registered cleanly
    -- while paused (no crash -- disproves the "registration itself crashes"
    -- theory for this incident). Crashed on RESUMING play. Log ends on 6
    -- back-to-back `onCharacterEat(Character, nil, Inventory)` firings, no
    -- Lua error printed before the cutoff -- foodItem was nil every time
    -- observed. NOT PROVEN: could be this hook choking on a real (non-nil)
    -- item reference the moment one actually came through, or could be an
    -- unrelated vanilla Kenshi crash (dense NPC areas are known crash-prone)
    -- that happened to land while this was running. Quarantined as the best
    -- available suspect rather than left live on an unproven guess either way.
    "onCharacterEat",
}
local function quarantined(name)
    for _, q in ipairs(QUARANTINE) do if q == name then return true end end
    return false
end

-- ---------------------------------------------------------------------------
function Observer.start()
    if type(registerHandler) ~= "function" then
        log("registerHandler unavailable -- cannot observe")
        return
    end
    if #Observer._handlers > 0 then
        log("already observing -- call Observer.stop() first to restart")
        return
    end

    local byTag = {}
    for _, e in ipairs(EVENTS) do
        if quarantined(e.event) then
            log("SKIP (quarantined): " .. e.event)
        else
            -- LOG-AS-CURSOR ON REGISTRATION ITSELF, not just on firing. If
            -- this crashes, the last "REGISTERING" line with no matching
            -- "registered ->" line right after it names the killer.
            log("REGISTERING: " .. e.event)
            local ok, hid = pcall(registerHandler, e.event, function(...)
                log(("[%s] %s(%s)"):format(e.tag, e.event, describeArgs(...)))
                -- NO return statement -- see the file header. This line is
                -- the entire safety contract for every OVERRIDE-category
                -- event above.
            end)
            if ok and hid then
                log("  registered -> ok")
                Observer._handlers[#Observer._handlers + 1] = hid
                byTag[e.tag] = (byTag[e.tag] or 0) + 1
            else
                log(("  FAILED to register %s -- %s"):format(e.event, tostring(hid)))
            end
        end
    end

    log(("observing -- %d/%d hook(s) armed"):format(#Observer._handlers, #EVENTS))
    for tag, n in pairs(byTag) do log(("  %-7s %d event(s)"):format(tag, n)) end
    log("Go play normally near varied content. Everything the engine's own AI")
    log("does across these systems prints here. Observer.stop() when done, then:")
    log("  python tools/readlog.py --tag OBS")
    log("  python tools/readlog.py --tag SLAVE   (or SHADOW, TAVERN, ECON, BUILD, LIFE, SKILL, JOBS)")
end

-- Observer.startOne("onLimbAmputated") -- register exactly ONE event by
-- name, for bisecting a crash without risking the rest of the batch. Not
-- tracked in Observer._handlers (Observer.stop() will not clear it) --
-- this is a scratch tool, not part of the normal session flow.
function Observer.startOne(eventName)
    if type(registerHandler) ~= "function" then
        log("registerHandler unavailable")
        return
    end
    local tag = "?"
    for _, e in ipairs(EVENTS) do if e.event == eventName then tag = e.tag end end
    log("REGISTERING (solo): " .. eventName)
    local ok, hid = pcall(registerHandler, eventName, function(...)
        log(("[%s] %s(%s)"):format(tag, eventName, describeArgs(...)))
    end)
    log(ok and ("  registered -> ok (handle " .. tostring(hid) .. ")")
             or ("  FAILED -- " .. tostring(hid)))
end

-- Observer.startTag("SLAVE") -- register only the events in one tag group.
-- A smaller blast radius than Observer.start()'s full 38 -- if a retry after
-- a crash still feels risky, work through tag groups one at a time instead
-- (JOBS, SLAVE, SHADOW, TAVERN, ECON, BUILD, LIFE, SKILL -- see Observer.list()).
-- Adds to whatever is already registered rather than replacing it, so
-- several startTag() calls compose; Observer.stop() clears everything
-- regardless of which function armed it.
function Observer.startTag(wantTag)
    if type(registerHandler) ~= "function" then
        log("registerHandler unavailable")
        return
    end
    local n = 0
    for _, e in ipairs(EVENTS) do
        if e.tag == wantTag and not quarantined(e.event) then
            log("REGISTERING: " .. e.event)
            local ok, hid = pcall(registerHandler, e.event, function(...)
                log(("[%s] %s(%s)"):format(e.tag, e.event, describeArgs(...)))
            end)
            if ok and hid then
                log("  registered -> ok")
                Observer._handlers[#Observer._handlers + 1] = hid
                n = n + 1
            else
                log("  FAILED -- " .. tostring(hid))
            end
        end
    end
    log(("%s: %d event(s) armed"):format(wantTag, n))
end

function Observer.stop()
    if type(unregisterHandler) ~= "function" or #Observer._handlers == 0 then
        log("not observing")
        return
    end
    for _, hid in ipairs(Observer._handlers) do pcall(unregisterHandler, hid) end
    Observer._handlers = {}
    log("observation stopped")
end

function Observer.list()
    local byTag = {}
    for _, e in ipairs(EVENTS) do
        byTag[e.tag] = byTag[e.tag] or {}
        table.insert(byTag[e.tag], e.event)
    end
    for tag, evs in pairs(byTag) do
        log(("%-7s: %s"):format(tag, table.concat(evs, ", ")))
    end
end

log("28_vanilla_observer loaded -- Observer.start() / .stop() / .list()")
log(("watching %d events across JOBS/SLAVE/SHADOW/TAVERN/ECON/BUILD/LIFE/SKILL"):format(#EVENTS))
