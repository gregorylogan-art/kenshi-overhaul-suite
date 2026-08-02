-- ============================================================================
-- FISHING SKILL MODEL  (Greg's design, v1.2)
--
-- CLASS FANTASY is the point: a character who fishes should visibly BECOME a
-- fisherman. Skill does not just add fish -- it removes the junk, so the same
-- action steadily turns from "pulling up trash" into "landing dinner".
--
-- Every skill REDUCES junk (Greg's correction). Fish absorbs whatever junk and
-- nothing give up, so the three bands always sum to 1.
--
--   Precision Shooting : junk -0.05%/lvl, nothing -0.02%/lvl   (aim/accuracy)
--   Swimming           : junk -0.10%/lvl                        (working the water)
--   Labouring          : junk -0.30%/lvl, cast -0.01s/lvl       (graft + speed)
--
-- At level 100 in all three: junk 80% -> 35%, nothing 5% -> 3%, fish 15% -> 62%.
--
-- Fishing also FEEDS those pools plus Perception, so the activity trains what it
-- uses -- very Kenshi.
--
-- THE TESTING PROBLEM (Greg): Kenshi XP takes forever, so playing to level 100
-- to check a curve is impossible. Fishing.simulate() runs the maths in-process
-- against arbitrary skill levels and prints the resulting distribution -- the
-- curve is verified in a second, with no grinding. The game only has to confirm
-- that skills are READ and XP is GRANTED correctly.
-- ============================================================================

local TAG = "[SKILL] "
local function log(m) print(TAG .. tostring(m)) end

-- HEARTBEAT: printed as the very first executable statement. The 2026-08-01
-- session saw ScriptLoader report this file as "loaded" while it produced ZERO
-- output and logged no error -- so we could not tell whether the body ran at
-- all. If this line is absent from the log, the chunk never executed (load or
-- compile failure); if it is present but later lines are missing, execution
-- died in between and the last line printed marks the spot.
log("=== 19_fishing_skill.lua BEGIN ===")

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
    local ok, v = pcall(function() return stats:getStat(id, false) end)
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
local ALLOW_XP = true

function Fishing.grantXp(character)
    if not ALLOW_XP then return "xp disabled (suspected character corruption)" end
    local okS, stats = pcall(function() return character:getStats() end)
    if not okS or not stats then return "no stats" end

    local parts = {}
    for _, key in ipairs({ "labouring", "swimming", "precisionShooting", "perception" }) do
        local id = Fishing.STAT[key]
        local amount = Fishing.SKILL_CFG.xpPerCast[key]
        if id and amount then
            local before = select(2, pcall(function() return stats:getStat(id, false) end))
            local ok, err = pcall(function() stats:xpStat_eventBased(id, amount) end)
            local after = select(2, pcall(function() return stats:getStat(id, false) end))
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

log("skill model loaded. Try:  Fishing.simulate()")
-- Auto-run wrapped: if the curve print throws, the failure is reported instead
-- of silently killing the tail of the file.
local okSim, simErr = pcall(Fishing.simulate)
if not okSim then log("simulate() FAILED: " .. tostring(simErr)) end
log("=== 19_fishing_skill.lua END (grantXp is " ..
    (type(Fishing.grantXp) == "function" and "READY" or "MISSING") .. ") ===")
