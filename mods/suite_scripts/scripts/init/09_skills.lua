-- ============================================================================
-- Kenshi Overhaul Suite -- SKILLS  (#14)
--
-- Generalised out of the fishing skill model, which worked but was welded to
-- one profession. Every future trade -- cooking, woodcutting, mining, foraging,
-- smithing -- trains stats, and each re-deriving "read a stat, grant xp, curve
-- an outcome" is how five subtly different versions appear and four are wrong.
--
-- THE HARD RULE, and it is not negotiable:
--     A STAT ID IS REGISTERED ONLY ONCE IT HAS BEEN MEASURED LIVE.
-- Guessing an id does not fail loudly -- it silently trains the WRONG SKILL,
-- and the player never finds out. `Skills.register` refuses an id that is not
-- marked measured, so a plausible-looking guess cannot slip in.
--
-- CONTRACT
--     Skills.register(key, id, measuredBy)   -> ok, reason
--     Skills.idOf(key)                       -> id|nil
--     Skills.read(character, key)            -> value            0 if unknown
--     Skills.grant(character, key, amount)   -> before, after
--     Skills.grantMany(character, table)     -> summary string
--     Skills.curve(params, skills)           -> value            PURE
--     Skills.selftest()                      -> boolean          no world
--
-- WHY read() PASSES unmodified=TRUE
-- getStat(id, false) returns the value AFTER encumbrance and hunger penalties,
-- so a character's skills appear to FALL as their pack fills. Feeding that into
-- an outcome curve makes a heavily-laden worker worse at their trade in a way
-- no design intended, and it looks like a balance problem rather than a bug.
-- ============================================================================

local TAG = "[SKILL] "
local function log(m) print(TAG .. tostring(m)) end

Skills = Skills or {}
pcall(function() _G.Skills = Skills end)   -- escape the per-script sandbox

-- [key] = { id = n, measuredBy = "how we know" }
-- Seeded ONLY with ids measured live during the fishing work.
Skills.registry = Skills.registry or {
    labouring         = { id = 3,  measuredBy = "fishing xp run 2026-08-02, skill tab moved" },
    swimming          = { id = 23, measuredBy = "fishing xp run 2026-08-02, skill tab moved" },
    perception        = { id = 24, measuredBy = "fishing xp run 2026-08-02, skill tab moved" },
    precisionShooting = { id = 36, measuredBy = "fishing xp run 2026-08-02, skill tab moved" },
}

-- Keys we know Kenshi has but whose ids are NOT measured. Listed explicitly so
-- they read as "known unknown" rather than "not thought about", and so a future
-- session knows exactly what to go and measure.
Skills.unmeasured = Skills.unmeasured or {
    "cooking", "fieldMedic", "athletics", "strength", "toughness",
    "meleeAttack", "meleeDefence", "dodge", "stealth", "lockpicking",
    "thievery", "assassination", "engineer", "robotics", "science",
    "weaponsmith", "armoursmith", "farming",
}

-- ---------------------------------------------------------------------------
-- Skills.register -- measured ids only
-- ---------------------------------------------------------------------------
function Skills.register(key, id, measuredBy)
    if type(key) ~= "string" or type(id) ~= "number" then
        return false, "bad arguments"
    end
    if type(measuredBy) ~= "string" or measuredBy == "" then
        -- The whole point of the module. An id without evidence is a guess, and
        -- a guess here trains the wrong skill silently.
        return false, "refused: no measuredBy evidence -- measure it live first"
    end
    Skills.registry[key] = { id = id, measuredBy = measuredBy }
    log(("registered %s = %d (%s)"):format(key, id, measuredBy))
    return true
end

function Skills.idOf(key)
    local e = Skills.registry[key]
    return e and e.id or nil
end

-- ---------------------------------------------------------------------------
-- Skills.read / grant
-- ---------------------------------------------------------------------------
function Skills.read(character, key)
    local id = Skills.idOf(key)
    if not id or not character then return 0 end
    local okS, stats = pcall(function() return character:getStats() end)
    if not okS or not stats then return 0 end
    -- unmodified = TRUE. See the header note: modified values fall with load.
    local okV, v = pcall(function() return stats:getStat(id, true) end)
    if okV and type(v) == "number" then return v end
    return 0
end

function Skills.grant(character, key, amount)
    local id = Skills.idOf(key)
    if not id or not character then return nil, nil end
    amount = tonumber(amount) or 0
    if amount <= 0 then return nil, nil end

    local okS, stats = pcall(function() return character:getStats() end)
    if not okS or not stats then return nil, nil end

    local before = Skills.read(character, key)
    -- pcall-wrapped: an unprotected throw here once aborted a whole catch before
    -- the item was granted, so the cast evaporated with no result line.
    local ok = pcall(function() stats:xpStat_eventBased(id, amount) end)
    if not ok then return before, before end
    return before, Skills.read(character, key)
end

-- Skills.grantMany(character, { labouring = 0.5, swimming = 0.3 })
function Skills.grantMany(character, grants)
    if type(grants) ~= "table" then return "no grants" end
    local parts = {}
    for key, amount in pairs(grants) do
        local before, after = Skills.grant(character, key, amount)
        if before then
            parts[#parts + 1] = ("%s %.3f->%.3f"):format(key, before, after)
        else
            parts[#parts + 1] = ("%s SKIPPED(unregistered)"):format(key)
        end
    end
    return table.concat(parts, "  ")
end

-- ---------------------------------------------------------------------------
-- Skills.curve -- PURE outcome shaping, testable with no world
-- ---------------------------------------------------------------------------
-- Generalises fishing's computeOdds. A profession declares a base value and how
-- much each skill moves it, and this clamps the result.
--
-- Kept pure deliberately: fishing's skill model sat INERT for a full session
-- because it was only reachable from a simulate() helper and the live path used
-- hard-coded numbers instead. A pure function with its own tests cannot rot that
-- way unnoticed.
--
--   params = { base = 0.80, min = 0.35, max = 0.95,
--              per = { precisionShooting = -0.0005, labouring = -0.003 } }
--   skills = { precisionShooting = 20, labouring = 10 }
function Skills.curve(params, skills)
    if type(params) ~= "table" then return 0 end
    local v = tonumber(params.base) or 0
    local per = params.per or {}
    skills = skills or {}
    for key, rate in pairs(per) do
        v = v + (tonumber(skills[key]) or 0) * (tonumber(rate) or 0)
    end
    if params.min and v < params.min then v = params.min end
    if params.max and v > params.max then v = params.max end
    return v
end

-- Read every registered skill at once -- what a curve wants as input.
function Skills.readAll(character, keys)
    local out = {}
    for _, key in ipairs(keys or {}) do
        out[key] = Skills.read(character, key)
    end
    return out
end

-- Skills.status() -- what is registered, and what is still a known unknown.
function Skills.status()
    log("REGISTERED (measured):")
    for key, e in pairs(Skills.registry) do
        log(("    %-20s id=%-4d %s"):format(key, e.id, e.measuredBy))
    end
    log("UNMEASURED (do not guess -- measure, then register):")
    log("    " .. table.concat(Skills.unmeasured, ", "))
end

-- ---------------------------------------------------------------------------
function Skills.selftest()
    local passed, failed = 0, 0
    local function check(name, cond)
        if cond then passed = passed + 1
        else failed = failed + 1 log("  FAIL: " .. name) end
    end

    check("seeded ids present", Skills.idOf("labouring") == 3
          and Skills.idOf("swimming") == 23
          and Skills.idOf("perception") == 24
          and Skills.idOf("precisionShooting") == 36)
    check("unknown key -> nil", Skills.idOf("nonesuch") == nil)

    -- THE important one: an id without evidence must be refused.
    check("register refuses an unevidenced id", Skills.register("cooking", 99) == false)
    check("...and did not register it", Skills.idOf("cooking") == nil)
    check("register accepts evidence", Skills.register("__t", 77, "measured in test") == true)
    check("...and stored it", Skills.idOf("__t") == 77)
    Skills.registry["__t"] = nil

    -- curve: pure, so fully checkable here
    local p = { base = 0.80, min = 0.35, max = 0.95,
                per = { precisionShooting = -0.001, labouring = -0.002 } }
    check("curve at zero skill = base", math.abs(Skills.curve(p, {}) - 0.80) < 1e-9)
    check("curve falls with skill", Skills.curve(p, { labouring = 100 }) < 0.80)
    check("curve clamps at min",
          Skills.curve(p, { labouring = 100000 }) == 0.35)
    check("curve clamps at max",
          Skills.curve({ base = 2, min = 0, max = 0.95 }, {}) == 0.95)
    check("curve survives nil skills", type(Skills.curve(p, nil)) == "number")
    check("curve survives nil params", Skills.curve(nil, {}) == 0)

    -- read/grant must not throw without a character
    check("read with no character = 0", Skills.read(nil, "labouring") == 0)
    check("grant with no character = nil", Skills.grant(nil, "labouring", 1) == nil)

    log(("--- SELFTEST: %d passed, %d failed ---"):format(passed, failed))
    return failed == 0
end

log("09_skills loaded -- Skills.status() / .read / .grant / .curve / .selftest()")
