-- ============================================================================
-- Kenshi Overhaul Suite -- RESUMABLE CAPABILITY PROBE (v2)
--
-- v1 CRASHED THE GAME. Lesson: pcall catches Lua errors but NOT native C++
-- access violations. You cannot make native probing crash-proof -- you can only
-- make crashes CHEAP and INFORMATIVE. v2 does that:
--
--   1. LOG-AS-CURSOR. Every binding is printed BEFORE it is called. The
--      KenshiLua log survives the crash, so the last "TRY" line with no
--      matching result names the exact killer. No io library needed.
--   2. QUARANTINE. Known crashers are listed below and never called again.
--      Each crash permanently buys one quarantined binding.
--   3. RISK ORDER. Fields (safest) -> primitive-returning methods ->
--      object-returning methods (most dangerous). Maximum value banked before
--      any risk is taken.
--   4. HIGH-VALUE FIRST. The fishing/water calls we actually need run before
--      the mass sweep, so a later crash cannot cost us them.
--   5. TICK-SLICED. A few probes per frame, so the log flushes between them and
--      the game does not hitch.
-- ============================================================================

local TAG = "[CAP] "
local function log(m) print(TAG .. tostring(m)) end

-- Bindings known to crash the game. Add "Class.member" here after each crash.
local QUARANTINE = {
    -- CONFIRMED CRASHERS. Each cost one game crash to discover.
    -- 2026-08-01: hard-crashed reading a container of pointers (lektor<Platoon*>).
    -- The whole container class is now excluded at generation time by
    -- tools/gen_probes.py, so these are belt-and-braces.
    "Faction.platoonKillList",
    "Faction.platoonRemoveList",
    "Faction.activePlatoons",
}

local PER_TICK = 20          -- probes per frame
local SCRIPTS = "mods/KenshiLua/scripts/"

-- ---------------------------------------------------------------------------
-- PHASE 1 -- HIGH VALUE. Runs first; these are the calls fishing depends on.
-- ---------------------------------------------------------------------------
local function highValue(char, stats, world, player)
    log("################ HIGH-VALUE (fishing/water) ################")

    local function try(label, fn)
        local ok, res = pcall(fn)
        if ok then
            log(("  HV OK    %s = %s"):format(label, tostring(res)))
        else
            log(("  HV ERR   %s -> %s"):format(label, tostring(res)))
        end
        return ok, res
    end

    if char then
        try("Character:getWaterLevel()", function() return char:getWaterLevel() end)
        try("Character:getPos()",        function() return char:getPos() end)
        try("Character:getHealth()",     function() return char:getHealth() end)
        try("Character:getName()",       function() return char:getName() end)
        try("Character.stealthMode",     function() return char.stealthMode end)
        try("Character.isOnScreen",      function() return char.isOnScreen end)
    end
    if stats then
        try("CharStats.swimming",                function() return stats.swimming end)
        try("CharStats:calculateSwimSpeed()",    function() return stats:calculateSwimSpeed() end)
        try("CharStats:calculateMaxSwimSpeed()", function() return stats:calculateMaxSwimSpeed() end)
    end
    if world then
        try("GameWorld.paused", function() return world.paused end)
    end
    if player then
        try("getSelectedCharacter()", function() return _G["getSelectedCharacter"]() end)
    end
    log("################ END HIGH-VALUE ################")
end

-- ---------------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------------
local function loadManifest()
    for _, f in ipairs({
        function() return dofile(SCRIPTS .. "probe_manifest.lua") end,
        function() return dofile("./" .. SCRIPTS .. "probe_manifest.lua") end,
    }) do
        local ok, res = pcall(f)
        if ok and type(res) == "table" then return res end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Build the work queue in RISK ORDER
-- ---------------------------------------------------------------------------
local PRIMITIVE = {
    boolean = true, number = true, integer = true, string = true,
    float = true, double = true, void = true,
}

local function buildQueue(manifest, specimens)
    local qFields, qPrim, qObj = {}, {}, {}
    local blocked = {}
    for _, k in ipairs(QUARANTINE) do blocked[k] = true end

    for _, s in ipairs(specimens) do
        local e = manifest[s.cls]
        if e then
            for _, f in ipairs(e.fields or {}) do
                local key = s.cls .. "." .. f.name
                if not blocked[key] then
                    qFields[#qFields + 1] = { s = s, kind = "field", name = f.name, info = f.ty .. " " .. f.rw, key = key }
                end
            end
            for _, m in ipairs(e.methods or {}) do
                local key = s.cls .. ":" .. m.name
                if not blocked[key] then
                    local item = { s = s, kind = "method", name = m.name, info = m.ret, key = key }
                    if PRIMITIVE[(m.ret or ""):lower()] then
                        qPrim[#qPrim + 1] = item
                    else
                        qObj[#qObj + 1] = item
                    end
                end
            end
        end
    end

    local q = {}
    for _, t in ipairs({ qFields, qPrim, qObj }) do
        for _, it in ipairs(t) do q[#q + 1] = it end
    end
    log(("queue: %d fields, %d primitive-methods, %d object-methods = %d total")
        :format(#qFields, #qPrim, #qObj, #q))
    return q
end

-- ---------------------------------------------------------------------------
-- Arm: wait for a character, then sweep tick-sliced
-- ---------------------------------------------------------------------------
local started, finished = false, false
local queue, qi = nil, 1
local tally = { ok = 0, nilret = 0, err = 0, missing = 0 }

local function gather()
    local function g(n)
        local f = _G[n]
        if type(f) ~= "function" then return nil end
        local ok, r = pcall(f)
        if ok then return r end
        return nil
    end
    local world  = g("getGameWorld")
    local player = g("getPlayerInterface")
    local char   = g("getSelectedCharacter")
    if not char and player then
        local ok, c = pcall(function() return player:getAnyPlayerCharacter() end)
        if ok then char = c end
    end

    local specimens = {}
    local function add(cls, obj, how)
        if obj ~= nil then specimens[#specimens + 1] = { cls = cls, obj = obj, how = how } end
    end
    add("GameWorld", world, "getGameWorld()")
    add("PlayerInterface", player, "getPlayerInterface()")
    add("Character", char, "selected/anyPlayerCharacter")

    local stats
    if char then
        for _, p in ipairs({
            { "CharStats", "getStats" }, { "Inventory", "getInventory" },
            { "CharMovement", "getMovement" }, { "Faction", "getFaction" },
        }) do
            local ok, o = pcall(function() return char[p[2]](char) end)
            if ok and o then
                add(p[1], o, "character:" .. p[2] .. "()")
                if p[1] == "CharStats" then stats = o end
            end
        end
    end
    return specimens, char, stats, world, player
end

local id
id = registerHandler("onCharsUpdate", function()
    if finished then return end

    -- ---- one-time setup ----
    if not started then
        local specimens, char, stats, world, player = gather()
        if not char then return end          -- keep waiting for a character
        started = true

        log("=========================================================")
        log("CAPABILITY PROBE v2 -- resumable, log-as-cursor")
        log("specimens: " .. #specimens)
        for _, s in ipairs(specimens) do log("  " .. s.cls .. " <- " .. s.how) end
        if #QUARANTINE > 0 then log("quarantined: " .. table.concat(QUARANTINE, ", ")) end

        highValue(char, stats, world, player)   -- bank the important data FIRST

        local manifest = loadManifest()
        if not manifest then
            log("FATAL: manifest not found")
            finished = true
            return
        end
        queue = buildQueue(manifest, specimens)
        log("--------- MASS SWEEP BEGIN (risk-ordered) ---------")
        return
    end

    -- ---- tick-sliced sweep ----
    for _ = 1, PER_TICK do
        if qi > #queue then
            finished = true
            if type(unregisterHandler) == "function" then pcall(unregisterHandler, id) end
            log("--------- MASS SWEEP COMPLETE ---------")
            log(("TOTALS ok=%d nil=%d broken=%d absent=%d")
                :format(tally.ok, tally.nilret, tally.err, tally.missing))
            return
        end

        local it = queue[qi]
        qi = qi + 1

        -- CURSOR: printed BEFORE the call. If the game dies, this is the killer.
        log(("TRY %d/%d %s"):format(qi - 1, #queue, it.key))

        if it.kind == "field" then
            local ok, res = pcall(function() return it.s.obj[it.name] end)
            if not ok then
                tally.err = tally.err + 1
                log(("  BROKEN %s err=%s"):format(it.key, tostring(res)))
            else
                tally.ok = tally.ok + 1
                log(("  OK %s (%s) = %s"):format(it.key, it.info, tostring(res)))
            end
        else
            if it.s.obj[it.name] == nil then
                tally.missing = tally.missing + 1
                log(("  ABSENT %s [doc: %s]"):format(it.key, it.info))
            else
                local ok, res = pcall(function() return it.s.obj[it.name](it.s.obj) end)
                if not ok then
                    tally.err = tally.err + 1
                    log(("  BROKEN %s err=%s"):format(it.key, tostring(res)))
                elseif res == nil then
                    tally.nilret = tally.nilret + 1
                    log(("  NIL %s [doc: %s]"):format(it.key, it.info))
                else
                    tally.ok = tally.ok + 1
                    log(("  OK %s = %s"):format(it.key, tostring(res)))
                end
            end
        end
    end
end)

log("probe v2 armed -- waiting for a character")
