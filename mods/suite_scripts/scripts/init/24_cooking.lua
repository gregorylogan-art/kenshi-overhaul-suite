-- ============================================================================
-- Kenshi Overhaul Suite -- COOKING  (the economy sink)   [#18]
--
-- WHY THIS EXISTS
-- Fishing is a faucet. Without a sink it is a money printer, which was Greg's
-- constraint from the start:
--     "raw fish need to be cooked to be eaten... the economy does not break,
--      we will have to add chance to burn fish"
--
-- So the chain costs something at every step:
--     Raw fish  --cook-->  Cooked fish        (worth more, edible)
--                     \->  Burnt fish         (worth almost nothing)
-- Burning is the sink. A fisher who cooks badly destroys value; skill reduces
-- the loss. That is what stops "fish -> sell" being free money.
--
-- ARCHITECTURE
-- This runs ENTIRELY on the catch bag and makes ZERO inventory calls. Raw fish
-- is consumed with Items.take and product is written back with Items.bank, so
-- an ingredient never has to enter a character's pack to be used. That is the
-- engine law from #37 -- a loop must not write to an inventory -- and cooking is
-- the first system built on it from the start rather than retrofitted.
--
-- CONTRACT
--     Cooking.canCook(character)  -> boolean, reason
--     Cooking.cook(character, n)  -> cooked, burnt, reason
--     Cooking.odds(skill)         -> burnChance          pure, testable
--     Cooking.selftest()          -> boolean             no world required
--
-- DEFERRED (issues, not silent gaps)
--   * Requiring a real campfire. Kenshi has cooking stations; binding to one
--     needs an actor query we have not verified, so v1 cooks anywhere and #43
--     tracks the restriction.
--   * A Cooking SKILL id. Ours are measured live (Labouring 3, Swimming 23,
--     Perception 24, Precision Shooting 36); Cooking's is unknown, so XP is
--     OFF until it is measured rather than guessed at a plausible number.
-- ============================================================================

local TAG = "[COOK] "
local function log(m) print(TAG .. tostring(m)) end

Cooking = Cooking or {}
pcall(function() _G.Cooking = Cooking end)   -- escape the per-script sandbox

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local CFG = {
    -- FCS items Greg authored and confirmed loading in-game:
    --   10- Raw Fish   12- Cooked Fish   14- Burnt Fish
    -- Names must match the FCS entries EXACTLY: getDataByName is case-sensitive
    -- and fails silently (#23), so a casing slip yields a system that quietly
    -- produces nothing.
    rawNames    = { "Raw Fish", "Small Fish" },   -- first that resolves wins
    cookedName  = "Cooked Fish",
    burntName   = "Burnt Fish",

    -- Burn chance at zero skill, and at maximum. Generous at the top end so the
    -- sink never fully closes -- a master cook still occasionally ruins one, and
    -- an economy with a truly lossless conversion is a printer again.
    burnAtZero  = 0.40,
    burnAtMax   = 0.05,
    maxSkill    = 100,

    -- Cooking XP is disabled until the stat id is MEASURED. Guessing an id and
    -- writing to it is how you silently train the wrong skill.
    cookingStatId = nil,
    xpPerCook     = 0.5,
}

-- ---------------------------------------------------------------------------
-- Pure odds -- testable with no world, no character, no engine
-- ---------------------------------------------------------------------------
-- Linear from burnAtZero down to burnAtMax. Kept pure deliberately: the fishing
-- skill model sat inert for a whole session because it was only reachable from
-- a simulate() helper, and nothing verified it against the live path.
function Cooking.odds(skill)
    skill = tonumber(skill) or 0
    if skill < 0 then skill = 0 end
    if skill > CFG.maxSkill then skill = CFG.maxSkill end
    local t = skill / CFG.maxSkill
    return CFG.burnAtZero + (CFG.burnAtMax - CFG.burnAtZero) * t
end

-- Which raw-fish name actually exists in this install.
local function rawNameFor(character)
    for _, n in ipairs(CFG.rawNames) do
        if Items and Items.resolve and Items.resolve(character, n) then return n end
    end
    -- Fall back to the first configured name: if nothing resolves, cooking will
    -- report "no raw fish banked" rather than pretending to work.
    return CFG.rawNames[1]
end

local function ownerKeyFor(character)
    local ok, name = pcall(function() return character:getName() end)
    return (ok and name) or "?"
end

-- ---------------------------------------------------------------------------
-- CONTRACT: canCook
-- ---------------------------------------------------------------------------
function Cooking.canCook(character)
    if not character then return false, "no character" end
    if not Items then return false, "items module not loaded" end
    local key = ownerKeyFor(character)
    local raw = rawNameFor(character)
    local bag = Items.bagOf(key)
    local have = bag[raw] or 0
    if have <= 0 then
        return false, ("no %s banked -- catch some first"):format(raw)
    end
    return true, ("%d %s ready to cook"):format(have, raw)
end

-- ---------------------------------------------------------------------------
-- CONTRACT: cook
-- ---------------------------------------------------------------------------
-- Consumes raw fish from the bag and banks the product back into the same bag.
-- No inventory call anywhere in this function -- deliberately, and permanently.
function Cooking.cook(character, n)
    n = tonumber(n) or 1
    if not character then return 0, 0, "no character" end
    if not Items then return 0, 0, "items module not loaded" end

    local key = ownerKeyFor(character)
    local raw = rawNameFor(character)
    local bag = Items.bagOf(key)
    local have = bag[raw] or 0
    if have <= 0 then return 0, 0, ("no %s banked"):format(raw) end
    if n > have then n = have end

    local skill = 0
    if Fishing and Fishing.readSkill then
        local ok, s = pcall(Fishing.readSkill, character, "labouring")
        if ok and type(s) == "number" then skill = s end
    end
    local burnChance = Cooking.odds(skill)

    local cooked, burnt = 0, 0
    for _ = 1, n do
        if not Items.take(key, raw, 1) then break end
        if math.random() < burnChance then
            Items.bank(key, CFG.burntName, 1)
            burnt = burnt + 1
        else
            Items.bank(key, CFG.cookedName, 1)
            cooked = cooked + 1
        end
    end

    -- XP stays off until the Cooking stat id is measured rather than guessed.
    if CFG.cookingStatId and Fishing and Fishing.grantStatXp then
        pcall(Fishing.grantStatXp, character, CFG.cookingStatId,
              CFG.xpPerCook * (cooked + burnt))
    end

    log(("%s: cooked %d, burnt %d (burn chance %.0f%% at skill %.1f)")
        :format(key, cooked, burnt, burnChance * 100, skill))
    return cooked, burnt, nil
end

-- Cooking.status() -- what is cookable right now.
function Cooking.status()
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then log("select a character first") return end
    local can, why = Cooking.canCook(c)
    log("can cook          : " .. tostring(can) .. "  (" .. tostring(why) .. ")")
    local skill = 0
    if Fishing and Fishing.readSkill then
        local okS, s = pcall(Fishing.readSkill, c, "labouring")
        if okS and type(s) == "number" then skill = s end
    end
    log(("burn chance       : %.0f%% at skill %.1f"):format(Cooking.odds(skill) * 100, skill))
    log(("raw item resolved : %s"):format(tostring(rawNameFor(c))))
    log(("cooked / burnt    : %s / %s"):format(CFG.cookedName, CFG.burntName))
end

-- ---------------------------------------------------------------------------
-- Selftest -- no world, no character, no engine calls
-- ---------------------------------------------------------------------------
function Cooking.selftest()
    local passed, failed = 0, 0
    local function check(name, cond)
        if cond then passed = passed + 1
        else failed = failed + 1 log("  FAIL: " .. name) end
    end

    check("odds at 0 = burnAtZero",   math.abs(Cooking.odds(0)   - CFG.burnAtZero) < 1e-9)
    check("odds at max = burnAtMax",  math.abs(Cooking.odds(100) - CFG.burnAtMax)  < 1e-9)
    check("odds monotonically fall",  Cooking.odds(0) > Cooking.odds(50) and Cooking.odds(50) > Cooking.odds(100))
    check("odds clamp below zero",    Cooking.odds(-50)  == Cooking.odds(0))
    check("odds clamp above max",     Cooking.odds(9999) == Cooking.odds(100))
    check("odds handle nil",          type(Cooking.odds(nil)) == "number")

    -- Conservation through the bag: N raw in must equal cooked + burnt out.
    if Items then
        local KEY = "__cooktest__"
        Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil
        Items.bank(KEY, "Raw Fish", 10)
        local bag = Items.bagOf(KEY)
        check("test bag seeded", bag["Raw Fish"] == 10)

        -- Drive the transform directly, so the check does not need a Character.
        local cooked, burnt = 0, 0
        for _ = 1, 10 do
            if Items.take(KEY, "Raw Fish", 1) then
                if math.random() < 0.4 then
                    Items.bank(KEY, CFG.burntName, 1) burnt = burnt + 1
                else
                    Items.bank(KEY, CFG.cookedName, 1) cooked = cooked + 1
                end
            end
        end
        check("nothing created or destroyed", cooked + burnt == 10)
        local b2 = Items.bagOf(KEY)
        check("raw fully consumed", (b2["Raw Fish"] or 0) == 0)
        check("product conserved",
              (b2[CFG.cookedName] or 0) + (b2[CFG.burntName] or 0) == 10)
        check("items invariants clean", #Items.verify() == 0)
        Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil
    end

    log(("--- SELFTEST: %d passed, %d failed ---"):format(passed, failed))
    return failed == 0
end

log("24_cooking loaded -- Cooking.status() / .cook(char, n) / .selftest()")
