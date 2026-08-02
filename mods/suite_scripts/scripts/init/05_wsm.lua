-- ============================================================================
-- WORLD STATE MANAGER (WSM) v0.1  --  Kenshi Overhaul Suite control plane
--
-- Kenshi owns BODIES; the WSM owns TRUTH. Our systems read and write here, and
-- the Projector is the only bridge that pushes truth onto live characters.
-- Nothing in this file touches the engine, so it is testable from the console
-- with the game paused or even at the main menu.
--
-- Loads FIRST (05_) so every later system can rely on WSM existing.
--
-- CONTRACT -- every durable change goes through Mutate:
--     1. APPLY   the mutator to one category
--     2. LOG     one history row (category, source, day)
--     3. TRIM    the rolling window (default 30 game-days)
-- ApplySnapshot deliberately BYPASSES this (bulk load must not spam history).
--
-- PORTED FROM StarFall AS PATTERNS, NOT CODE (see docs/references/
-- STARFALL_WSM_CHERRYPICK.md): mutate-only writes, event history + rolling trim,
-- snapshot/restore, cvars default 0, dormant-vs-living agents, GUID%N batching.
--
-- TWO BUGS FROM StarFall DELIBERATELY DESIGNED OUT -- both are tick-catch-up
-- faults, and this file has a tick catch-up:
--   1. WRAPPING-COUNTER FREEZE. A guard like `if now <= last then return end`
--      against a counter that WRAPS silently kills the system forever. Our day
--      counter is MONOTONIC and never wraps; see WSM.advanceDay.
--   2. WATERMARK ADVANCED OUTSIDE THE READY GATE. Never mark work processed
--      when it did not actually run. WSM.catchUp only advances the watermark
--      for days whose handler genuinely executed.
-- ============================================================================

local TAG = "[WSM] "

-- DEFERRED LOGGING -- print() during ScriptLoader's init pass GOES NOWHERE.
-- Proven by elimination: 05_wsm and 19_fishing_skill both reported as "loaded"
-- and produced zero output, while 10_fishing's only output came from a HANDLER.
-- The logger is not capturing stdout yet when init scripts are executed. So
-- queue anything logged at load time and flush it on the first tick.
local _pending = {}
local _flushed = false
local function log(m)
    local s = TAG .. tostring(m)
    if _flushed then print(s) else _pending[#_pending + 1] = s end
end

if type(registerHandler) == "function" then
    local id
    id = registerHandler("onCharsUpdate", function()
        if _flushed then return end
        _flushed = true
        for _, s in ipairs(_pending) do print(s) end
        _pending = {}
        if type(unregisterHandler) == "function" then pcall(unregisterHandler, id) end
    end)
else
    _flushed = true   -- no handler system: print directly and hope
end

log("=== 05_wsm.lua BEGIN ===")

WSM = WSM or {}

-- ---------------------------------------------------------------------------
-- CVARS -- all default 0/off. Nothing the suite adds is on by default.
-- ---------------------------------------------------------------------------
WSM.cvar = WSM.cvar or {
    ["kos.wsm.debug"]        = 0,   -- verbose mutate logging
    ["kos.wsm.historyDays"]  = 30,  -- rolling window
    ["kos.projector.enable"] = 0,   -- body binding (not built yet)
}

function WSM.setCvar(name, value)
    if WSM.cvar[name] == nil then
        log("unknown cvar: " .. tostring(name))
        return false
    end
    WSM.cvar[name] = value
    log(("cvar %s = %s"):format(name, tostring(value)))
    return true
end

-- ---------------------------------------------------------------------------
-- CATEGORIES -- Phase 1 only. Do NOT add more until a shipped system needs one.
-- ---------------------------------------------------------------------------
local CATEGORIES = {
    time        = true,   -- monotonic day/hour
    economy     = true,   -- vendor stock, fish pressure, production
    settlements = true,   -- town id -> boards, stock links
    npcs        = true,   -- LOGICAL npcs only (id, role, home, flags)
    player      = true,   -- slavery rep, notoriety
    events      = true,   -- rolling history + rumor seeds
}

local function freshState()
    return {
        time        = { day = 0, hour = 0 },
        economy     = { fishPressure = {}, vendorStock = {} },
        settlements = {},
        npcs        = {},
        player      = { slaveryRep = 0, notoriety = 0 },
        events      = {},
    }
end

WSM.state = WSM.state or freshState()

-- ---------------------------------------------------------------------------
-- HISTORY -- rolling window, trimmed by GAME DAY not row count, so a quiet
-- stretch cannot evict recent rows and a busy day cannot blow memory.
-- ---------------------------------------------------------------------------
WSM.history = WSM.history or {}

local function trimHistory()
    local keepDays = WSM.cvar["kos.wsm.historyDays"] or 30
    local cutoff = WSM.state.time.day - keepDays
    if cutoff <= 0 then return end
    local kept = {}
    for _, row in ipairs(WSM.history) do
        if row.day >= cutoff then kept[#kept + 1] = row end
    end
    WSM.history = kept
end

-- ---------------------------------------------------------------------------
-- SUBSCRIPTIONS -- category dirty -> notify AFTER the mutate window closes, so
-- a subscriber can never observe a half-applied write or re-enter a mutation.
-- ---------------------------------------------------------------------------
WSM.subs = WSM.subs or {}
local inMutate = false
local pendingDirty = {}

function WSM.subscribe(category, fn)
    if not CATEGORIES[category] then
        log("subscribe: unknown category " .. tostring(category))
        return nil
    end
    WSM.subs[category] = WSM.subs[category] or {}
    table.insert(WSM.subs[category], fn)
    return #WSM.subs[category]
end

local function flushDirty()
    local dirty = pendingDirty
    pendingDirty = {}
    for category in pairs(dirty) do
        for _, fn in ipairs(WSM.subs[category] or {}) do
            local ok, err = pcall(fn, category)
            if not ok then log("subscriber error (" .. category .. "): " .. tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- MUTATE -- the ONLY durable write path.
-- ---------------------------------------------------------------------------
function WSM.mutate(category, fn, source)
    if not CATEGORIES[category] then
        log("mutate: unknown category " .. tostring(category))
        return false
    end
    if inMutate then
        -- Re-entrant mutation is how you get half-applied state and infinite
        -- loops. Refuse loudly rather than corrupt quietly.
        log("mutate: RE-ENTRANT write refused (" .. category .. " from " .. tostring(source) .. ")")
        return false
    end

    inMutate = true
    local ok, err = pcall(fn, WSM.state[category])
    inMutate = false

    if not ok then
        log(("mutate %s FAILED (%s): %s"):format(category, tostring(source), tostring(err)))
        return false
    end

    WSM.history[#WSM.history + 1] = {
        day      = WSM.state.time.day,
        hour     = WSM.state.time.hour,
        category = category,
        source   = source or "?",
    }
    trimHistory()

    pendingDirty[category] = true
    flushDirty()

    if (WSM.cvar["kos.wsm.debug"] or 0) ~= 0 then
        log(("mutate %s by %s (day %d)"):format(category, tostring(source), WSM.state.time.day))
    end
    return true
end

-- READ -- returns the live table. Lua cannot truly freeze it, so the CONTRACT
-- is: never write through a get(). Writes go through mutate, always.
function WSM.get(category)
    return WSM.state[category]
end

-- ---------------------------------------------------------------------------
-- TIME -- MONOTONIC. This is the StarFall wrapping-day bug designed out: the
-- day counter only ever increases, so `if day <= lastProcessed` can never
-- freeze a system permanently.
-- ---------------------------------------------------------------------------
function WSM.advanceDay(n)
    n = n or 1
    if n <= 0 then return end
    WSM.mutate("time", function(t)
        t.day = t.day + n
        t.hour = 0
    end, "advanceDay")
end

function WSM.day() return WSM.state.time.day end

-- CATCH-UP -- runs handler(day) for each missed day. The watermark advances
-- ONLY for days the handler actually completed (StarFall bug #2 designed out):
-- if the handler fails or reports not-ready, the day is retried next pass
-- rather than silently lost forever.
function WSM.catchUp(key, handler, maxDays)
    WSM.watermarks = WSM.watermarks or {}
    local last = WSM.watermarks[key]
    local today = WSM.day()

    if last == nil then                 -- first ever run: adopt today, do no work
        WSM.watermarks[key] = today
        return 0
    end
    if today <= last then return 0 end

    local todo = math.min(today - last, maxDays or 30)
    local done = 0
    for i = 1, todo do
        local d = last + i
        local ok, ran = pcall(handler, d)
        if not ok then
            log(("catchUp[%s] day %d errored: %s"):format(key, d, tostring(ran)))
            break                        -- do NOT advance past a failed day
        end
        if ran == false then break end    -- handler says not ready: retry later
        done = done + 1
        WSM.watermarks[key] = d          -- advance ONLY for completed work
    end
    return done
end

-- ---------------------------------------------------------------------------
-- SNAPSHOT / RESTORE -- bulk paths deliberately bypass mutate (no history spam).
-- ---------------------------------------------------------------------------
local function deepCopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, val in pairs(v) do out[deepCopy(k, seen)] = deepCopy(val, seen) end
    return out
end

function WSM.snapshot()
    return { version = 1, state = deepCopy(WSM.state), history = deepCopy(WSM.history) }
end

function WSM.applySnapshot(snap)
    if type(snap) ~= "table" or type(snap.state) ~= "table" then
        log("applySnapshot: malformed snapshot")
        return false
    end
    WSM.state = deepCopy(snap.state)
    WSM.history = deepCopy(snap.history or {})
    for category in pairs(CATEGORIES) do
        if WSM.state[category] == nil then WSM.state[category] = freshState()[category] end
        pendingDirty[category] = true
    end
    flushDirty()
    log("snapshot applied (day " .. tostring(WSM.state.time.day) .. ")")
    return true
end

function WSM.reset()
    WSM.state, WSM.history, WSM.watermarks = freshState(), {}, {}
    log("state reset")
end

-- ---------------------------------------------------------------------------
-- DEBUG / SELF-TEST -- runs without the game, so the contract is verifiable
-- from the console instantly (the same trick that made the fishing curve
-- testable without grinding XP).
-- ---------------------------------------------------------------------------
function WSM.dump()
    log(("day=%d  history=%d rows  npcs=%d  settlements=%d")
        :format(WSM.state.time.day, #WSM.history,
                (function() local n = 0 for _ in pairs(WSM.state.npcs) do n = n + 1 end return n end)(),
                (function() local n = 0 for _ in pairs(WSM.state.settlements) do n = n + 1 end return n end)()))
end

function WSM.selftest()
    log("--- WSM SELFTEST ---")
    local pass, fail = 0, 0
    local function check(name, cond)
        if cond then pass = pass + 1 else fail = fail + 1 log("  FAIL " .. name) end
    end

    WSM.reset()
    check("fresh day is 0", WSM.day() == 0)

    check("mutate returns true", WSM.mutate("player", function(p) p.notoriety = 5 end, "test"))
    check("mutate applied", WSM.get("player").notoriety == 5)
    check("history logged", #WSM.history == 1)

    check("unknown category refused", WSM.mutate("nope", function() end, "test") == false)

    -- re-entrancy must be refused, not silently allowed
    local reentered = true
    WSM.mutate("economy", function()
        reentered = WSM.mutate("player", function() end, "inner")
    end, "outer")
    check("re-entrant write refused", reentered == false)

    -- monotonic time
    WSM.advanceDay(3)
    check("day advanced", WSM.day() == 3)
    WSM.advanceDay(-5)
    check("negative advance ignored", WSM.day() == 3)

    -- catch-up must not advance past a failing day
    WSM.watermarks = { t = 0 }
    local seen = {}
    WSM.catchUp("t", function(d)
        seen[#seen + 1] = d
        if d == 2 then error("boom") end
    end, 10)
    check("catchUp stopped at failure", WSM.watermarks.t == 1)

    -- snapshot round-trip
    local snap = WSM.snapshot()
    WSM.mutate("player", function(p) p.notoriety = 99 end, "test")
    WSM.applySnapshot(snap)
    check("snapshot restored", WSM.get("player").notoriety == 5)

    WSM.reset()
    log(("--- SELFTEST: %d passed, %d failed ---"):format(pass, fail))
    return fail == 0
end

log("WSM v0.1 ready. Try:  WSM.selftest()   WSM.dump()")
log("=== 05_wsm.lua END ===")
