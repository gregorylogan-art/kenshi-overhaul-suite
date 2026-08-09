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
--
-- v0.2 (2026-08-08) -- read StarFall's real WorldStateManager.h (~1400 lines:
-- hot mirrors, settlement aggregates, witness rings, batch mutation scopes) to
-- see what a WSM looks like at 2000+ NPCs. Almost none of it belongs here --
-- this WSM has six flat categories and no per-entity registry yet, so porting
-- SoA hot-mirrors would be solving a problem we do not have. Four ideas DID
-- scale down cleanly and are new in this version:
--   * WSM.verify()        -- the same numbered-invariant-contract shape Items/
--                             Economy/Storage already use in this repo, applied
--                             to the WSM itself (StarFall's VerifyWorldStateInvariants).
--   * WSM.queryHistory()  -- filter EventHistory by category/source/day, so a
--                             batch-test session answers "what actually wrote
--                             economy today" without grepping raw prints
--                             (StarFall's QueryWhy, minus the entity-id/ring
--                             machinery we have no use for yet).
--   * WSM.batchOf()       -- the GUID%N batching this file's header has PROMISED
--                             since v0.1 and never delivered. Pure, tested, ready
--                             for whichever town/NPC system needs it first.
--   * WSM.stats           -- reentrancy-refusal and mutate-failure counters, so
--                             a soak session ends with a number to report instead
--                             of a log to re-read (Greg: "if it crashes even
--                             better, more information").
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

-- PUBLISH TO THE REAL GLOBAL TABLE. KenshiLua sandboxes each script, so a bare
-- global write stays private to this file and the console cannot see WSM at all
-- (proved live: `attempt to index global 'Fishing' (a nil value)` from the
-- script editor). Writing through _G escapes the private env.
--
-- This is also the mechanism the WSM needs to be a genuine control plane rather
-- than one file's private table: other suite scripts reach it as _G.WSM.
pcall(function() _G.WSM = WSM end)

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

-- Session counters, not saved. Cheap to bump, cheap to read after a soak --
-- the point is a number to report, not a log to re-read.
WSM.stats = WSM.stats or { mutateOk = 0, mutateFailed = 0, reentrantRefused = 0, unknownCategoryRefused = 0 }

-- [category] = { source, day, hour } for the most recent SUCCESSFUL mutate.
-- Cheap "who touched this last" without walking history.
WSM.lastMutateBy = WSM.lastMutateBy or {}

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
        WSM.stats.unknownCategoryRefused = WSM.stats.unknownCategoryRefused + 1
        return false
    end
    if inMutate then
        -- Re-entrant mutation is how you get half-applied state and infinite
        -- loops. Refuse loudly rather than corrupt quietly.
        log("mutate: RE-ENTRANT write refused (" .. category .. " from " .. tostring(source) .. ")")
        WSM.stats.reentrantRefused = WSM.stats.reentrantRefused + 1
        return false
    end

    inMutate = true
    local ok, err = pcall(fn, WSM.state[category])
    inMutate = false

    if not ok then
        log(("mutate %s FAILED (%s): %s"):format(category, tostring(source), tostring(err)))
        WSM.stats.mutateFailed = WSM.stats.mutateFailed + 1
        return false
    end
    WSM.stats.mutateOk = WSM.stats.mutateOk + 1

    WSM.history[#WSM.history + 1] = {
        day      = WSM.state.time.day,
        hour     = WSM.state.time.hour,
        category = category,
        source   = source or "?",
    }
    trimHistory()

    WSM.lastMutateBy[category] = { source = source or "?", day = WSM.state.time.day, hour = WSM.state.time.hour }

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
    WSM.stats = { mutateOk = 0, mutateFailed = 0, reentrantRefused = 0, unknownCategoryRefused = 0 }
    WSM.lastMutateBy = {}
    log("state reset")
end

-- ---------------------------------------------------------------------------
-- BATCH -- GUID%N-shaped batching. Promised in this file's header since v0.1
-- ("cherry-picked ... GUID%N batching") and never delivered because nothing
-- in this WSM iterates enough entities yet to need it. Pure and tested now,
-- ahead of the town/NPC registry that will actually call it (#28, #33), so
-- that system does not have to invent its own hashing on day one.
--
-- `key` is whatever stable identifier the caller has -- a Kenshi character
-- name today, a GUID/handle later. Lua has no native GUID type here, so this
-- hashes the string deterministically (same key -> same batch, always) rather
-- than assuming a numeric id.
-- ---------------------------------------------------------------------------
WSM.BATCH_COUNT = 4

function WSM.batchOf(key, n)
    n = n or WSM.BATCH_COUNT
    if type(n) ~= "number" or n <= 0 then return 0 end
    local s = tostring(key)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 2147483647
    end
    return h % math.floor(n)
end

-- ---------------------------------------------------------------------------
-- QUERY -- filtered read over EventHistory. StarFall's QueryWhy answers "why
-- did this change" over a much bigger event surface (entity ids, an audit
-- ring); this is the slim slice that actually matters here: "what wrote
-- category X, from source Y, since day Z" -- the question a batch-test session
-- asks after the fact, instead of grepping raw [WSM] prints for a mutate line.
--
-- filter = { category=?, source=?, sinceDay=? }  -- all optional, AND'd together
-- ---------------------------------------------------------------------------
function WSM.queryHistory(filter)
    filter = filter or {}
    local out = {}
    for _, row in ipairs(WSM.history) do
        local ok = true
        if filter.category and row.category ~= filter.category then ok = false end
        if ok and filter.source and row.source ~= filter.source then ok = false end
        if ok and filter.sinceDay and row.day < filter.sinceDay then ok = false end
        if ok then out[#out + 1] = row end
    end
    return out
end

-- ============================================================================
-- WSM INVARIANT CONTRACT -- executable via WSM.verify(). Same numbered shape
-- Items/Economy/Storage already use in this repo (cherry-picked one level up
-- from StarFall's VerifyWorldStateInvariants, #3637): the rules are CHECKED,
-- not just documented in this header where they can rot unnoticed.
--   1. History bound: every history row's day falls within kos.wsm.historyDays
--      of the current day -- trimHistory's job, checked rather than assumed.
--   2. Known categories only: every history row names a live CATEGORIES key.
--   3. Watermark sanity: no catch-up watermark sits in the future relative to
--      the current day (a watermark ahead of "now" can only mean corrupted
--      state, never legitimate progress).
--   4. Schema integrity: WSM.state has exactly the CATEGORIES keys -- nothing
--      missing, nothing orphaned by a stale snapshot from an older version.
--   5. Rest state: verify() must never observe bInMutate held true -- that
--      would mean a mutate crashed without unwinding the flag.
-- ============================================================================
function WSM.verify()
    local v = {}
    local today = WSM.state.time.day
    local keepDays = WSM.cvar["kos.wsm.historyDays"] or 30

    for i, row in ipairs(WSM.history) do
        -- INV1 history bound
        if row.day < today - keepDays then
            v[#v + 1] = ("[INV1] history row %d (day %d) outside the %d-day window (today=%d)")
                :format(i, row.day, keepDays, today)
        end
        -- INV2 known categories only
        if not CATEGORIES[row.category] then
            v[#v + 1] = ("[INV2] history row %d names unknown category %s"):format(i, tostring(row.category))
        end
    end

    -- INV3 watermark sanity
    for key, day in pairs(WSM.watermarks or {}) do
        if day > today then
            v[#v + 1] = ("[INV3] watermark[%s]=%d is AHEAD of today (%d)"):format(key, day, today)
        end
    end

    -- INV4 schema integrity: exact key-set match, both directions
    for category in pairs(CATEGORIES) do
        if WSM.state[category] == nil then
            v[#v + 1] = ("[INV4] state missing category %s"):format(category)
        end
    end
    for category in pairs(WSM.state) do
        if not CATEGORIES[category] then
            v[#v + 1] = ("[INV4] state has orphan category %s (not in CATEGORIES)"):format(category)
        end
    end

    -- INV5 rest state
    if inMutate then
        v[#v + 1] = "[INV5] verify() called while bInMutate is still true -- a mutate did not unwind"
    end

    return v
end

-- ---------------------------------------------------------------------------
-- DEBUG / SELF-TEST -- runs without the game, so the contract is verifiable
-- from the console instantly (the same trick that made the fishing curve
-- testable without grinding XP).
-- ---------------------------------------------------------------------------
local function countOf(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Generic per-category manifest -- StarFall's DescribeCategories, scaled down.
-- Lua tables are already self-describing, so this just standardizes "how big
-- is each category" instead of hand-picking two (npcs, settlements) and
-- leaving the rest invisible to WSM.dump().
function WSM.describe()
    local out = {}
    for category in pairs(CATEGORIES) do
        local v = WSM.state[category]
        out[category] = (type(v) == "table") and countOf(v) or 1
    end
    return out
end

function WSM.dump()
    local d = WSM.describe()
    local parts = {}
    for category in pairs(CATEGORIES) do
        parts[#parts + 1] = category .. "=" .. tostring(d[category])
    end
    table.sort(parts)
    log(("day=%d  history=%d rows  stats(ok=%d fail=%d reentrant=%d)  %s")
        :format(WSM.state.time.day, #WSM.history,
                WSM.stats.mutateOk, WSM.stats.mutateFailed, WSM.stats.reentrantRefused,
                table.concat(parts, "  ")))
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

    -- v0.2: verify() must be clean on a freshly reset WSM
    WSM.reset()
    check("verify clean on fresh state", #WSM.verify() == 0)

    -- v0.2: invariant contract actually catches breaks, not just documents them
    WSM.watermarks = { future = 999 }
    local viol = WSM.verify()
    local sawFutureWatermark = false
    for _, m in ipairs(viol) do if m:find("INV3") then sawFutureWatermark = true end end
    check("verify catches a future watermark", sawFutureWatermark)
    WSM.watermarks = {}

    -- v0.2: stats actually count what happened
    local before = WSM.stats.mutateOk
    WSM.mutate("player", function(p) p.notoriety = 1 end, "test")
    check("stats.mutateOk incremented", WSM.stats.mutateOk == before + 1)
    local reentBefore = WSM.stats.reentrantRefused
    WSM.mutate("economy", function() WSM.mutate("player", function() end, "inner2") end, "outer2")
    check("stats.reentrantRefused incremented", WSM.stats.reentrantRefused == reentBefore + 1)
    check("lastMutateBy recorded the source", WSM.lastMutateBy.player.source == "test")

    -- v0.2: queryHistory filters correctly
    WSM.reset()
    WSM.mutate("player", function(p) p.notoriety = 1 end, "sourceA")
    WSM.mutate("economy", function() end, "sourceB")
    WSM.mutate("player", function(p) p.notoriety = 2 end, "sourceA")
    check("queryHistory filters by category", #WSM.queryHistory({ category = "economy" }) == 1)
    check("queryHistory filters by source", #WSM.queryHistory({ source = "sourceA" }) == 2)
    check("queryHistory unfiltered returns everything", #WSM.queryHistory({}) == 3)
    check("queryHistory sinceDay excludes nothing on day 0", #WSM.queryHistory({ sinceDay = 0 }) == 3)

    -- v0.2: batchOf is deterministic, bounded, and spreads keys
    check("batchOf is deterministic", WSM.batchOf("Fisher Bob", 4) == WSM.batchOf("Fisher Bob", 4))
    check("batchOf stays in range", WSM.batchOf("Fisher Bob", 4) >= 0 and WSM.batchOf("Fisher Bob", 4) < 4)
    check("batchOf(n=1) is always 0", WSM.batchOf("anyone", 1) == 0)
    do
        local seen = {}
        for i = 1, 40 do seen[WSM.batchOf("npc" .. i, 4)] = true end
        check("batchOf spreads 40 keys across more than one bucket", countOf(seen) > 1)
    end

    -- v0.2: describe() reports every category, not just the two dump() used to
    do
        local d = WSM.describe()
        local allPresent = true
        for category in pairs({ time = true, economy = true, settlements = true,
                                 npcs = true, player = true, events = true }) do
            if d[category] == nil then allPresent = false end
        end
        check("describe covers every category", allPresent)
    end

    WSM.reset()
    log(("--- SELFTEST: %d passed, %d failed ---"):format(pass, fail))
    return fail == 0
end

log("WSM v0.2 ready. Try:  WSM.selftest()   WSM.dump()   WSM.verify()   WSM.queryHistory({})")
log("=== 05_wsm.lua END ===")
