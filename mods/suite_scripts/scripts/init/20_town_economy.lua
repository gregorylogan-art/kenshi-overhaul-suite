-- ============================================================================
-- Kenshi Overhaul Suite -- TOWN ECONOMY: economic specialization  (#48, child of #28)
--
-- Greg: every town has some stone, but each town has ONE mineral or farming
-- specialty that visibly signals its economic identity.
--
-- WHY THIS ONE FIRST
-- Of the town-economy batch (#46-#50), this is the only slice with no
-- unresolved engine question and no missing prerequisite. #46 (mining) and
-- #47 (water) both need NPCs that can be assigned to work a node -- that
-- labor-abstraction layer does not exist yet (Alive Core #33 / Projector #34
-- are both still open). So this module produces ABSTRACTLY: a settlement's
-- stock grows on a WSM day tick with no physical NPC ever shown mining
-- anything. Stated plainly, rather than allowed to drift silently from
-- "physical" to "abstract" the way a design doc can -- see #46's own honesty
-- rule, which this module follows on day one instead of only in hindsight.
--
-- CONTRACT (stable; internals are disposable)
--     TownEconomy.registerTown(key, specialty) -> ok, reason
--     TownEconomy.processDay(day)              -> ranOk   (WSM.catchUp handler shape)
--     TownEconomy.catchUpTo(maxDays)            -> daysRun
--     TownEconomy.stockOf(key)                  -> table
--     TownEconomy.specialtyOf(key)               -> string|nil
--     TownEconomy.verify()                      -> violations[]
--     TownEconomy.selftest()                    -> boolean
--
-- Extends WSM's existing `settlements` category (05_wsm.lua) rather than
-- keeping a second parallel store -- the same reason Storage.lua is `Items`
-- with a non-character owner instead of a second ledger.
--
-- WSM.catchUp, EXERCISED FOR REAL. Until now `WSM.catchUp` only ever ran
-- inside WSM's own selftest against a synthetic handler. processDay is
-- written to the exact contract that machinery expects -- return false when
-- not ready (here: the cvar is off) -- so disabling this mid-session cannot
-- lose a day: the watermark simply does not advance while off, and every
-- missed day replays automatically the next time it is re-enabled. This is
-- the "watermark advanced outside the ready gate" bug WSM's header was
-- written to design out, now proven against a real caller instead of only a
-- test double.
-- ============================================================================

local TAG = "[TOWNECON] "
local function log(m) print(TAG .. tostring(m)) end

TownEconomy = TownEconomy or {}
pcall(function() _G.TownEconomy = TownEconomy end)

-- ---------------------------------------------------------------------------
-- CVAR -- default 0/off, same shape as WSM.cvar/WSM.setCvar so a future
-- module can copy this instead of hand-rolling a one-off setter per flag.
-- ---------------------------------------------------------------------------
TownEconomy.cvar = TownEconomy.cvar or {
    ["kos.town.specialty.enable"] = 0,
}

function TownEconomy.setCvar(name, value)
    if TownEconomy.cvar[name] == nil then
        log("unknown cvar: " .. tostring(name))
        return false
    end
    TownEconomy.cvar[name] = value
    log(("cvar %s = %s"):format(name, tostring(value)))
    return true
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------
local CFG = {
    baseStonePerDay   = 2,   -- every town, always -- "each town will have some stone"
    specialtyPerDay   = 5,   -- the town's OWN specialty resource
    offSpecialtyPerDay = 1,  -- trace production of the OTHER specialty resources
}

-- One resource per specialty. Stone is baseline (every town produces it), so
-- it is deliberately not a specialty a town can be assigned -- being "the
-- stone town" would not read as a specialty at all.
local SPECIALTY_RESOURCE = {
    iron    = "iron",
    copper  = "copper",
    farming = "food",
}

local RESOURCES = { "stone", "iron", "copper", "food" }

local function freshStock()
    return { stone = 0, iron = 0, copper = 0, food = 0 }
end

-- ---------------------------------------------------------------------------
-- TownEconomy.registerTown -- assign a specialty, seed the WSM record
-- ---------------------------------------------------------------------------
function TownEconomy.registerTown(key, specialty)
    if type(key) ~= "string" or key == "" then return false, "bad key" end
    if not SPECIALTY_RESOURCE[specialty] then
        return false, "unknown specialty: " .. tostring(specialty)
    end
    return WSM.mutate("settlements", function(s)
        s[key] = s[key] or {}
        s[key].specialty = specialty
        s[key].stock = s[key].stock or freshStock()
    end, "TownEconomy.registerTown")
end

function TownEconomy.stockOf(key)
    local s = WSM.get("settlements")[key]
    return s and s.stock or freshStock()
end

function TownEconomy.specialtyOf(key)
    local s = WSM.get("settlements")[key]
    return s and s.specialty or nil
end

-- ---------------------------------------------------------------------------
-- TownEconomy.processDay -- WSM.catchUp handler shape: return false when not
-- ready (here: disabled), so the watermark does NOT advance and no day is
-- lost -- catchUp replays the missed days once re-enabled. See the file
-- header for why this matters.
-- ---------------------------------------------------------------------------
function TownEconomy.processDay(day)
    if (TownEconomy.cvar["kos.town.specialty.enable"] or 0) == 0 then
        return false   -- not ready: caller (WSM.catchUp) must retry, not skip
    end
    WSM.mutate("settlements", function(settlements)
        for _, town in pairs(settlements) do
            if town.specialty then
                town.stock = town.stock or freshStock()
                town.stock.stone = town.stock.stone + CFG.baseStonePerDay
                local mine = SPECIALTY_RESOURCE[town.specialty]
                for _, resName in ipairs({ "iron", "copper", "food" }) do
                    if resName == mine then
                        town.stock[resName] = town.stock[resName] + CFG.specialtyPerDay
                    else
                        town.stock[resName] = town.stock[resName] + CFG.offSpecialtyPerDay
                    end
                end
            end
        end
    end, "TownEconomy.processDay")
    return true
end

-- Console convenience: advance the town-economy watermark up to WSM's
-- current day, catching up any missed days via WSM's own machinery.
function TownEconomy.catchUpTo(maxDays)
    return WSM.catchUp("townEconomy", TownEconomy.processDay, maxDays or 30)
end

-- ============================================================================
-- INVARIANT CONTRACT -- executable via TownEconomy.verify(). Same numbered
-- shape Items/Economy/Storage/WSM already use in this repo.
--   1. Valid specialty: every registered town's specialty is a known key.
--   2. Schema integrity: every town's stock has exactly the RESOURCES keys.
--   3. Non-negative stock: production only ever adds; nothing here consumes,
--      so a negative or non-numeric value can only mean external corruption.
--
-- DELIBERATELY NOT an invariant here: "stock never decreases across calls."
-- A first draft tracked a module-level high-water mark for that, and it was
-- wrong -- WSM.reset()/applySnapshot() (both legitimate, used for save/load)
-- bypass TownEconomy entirely and would zero the stock while the stale
-- high-water mark stayed put, so the very next verify() would report
-- corruption that never happened. That check belongs in a regression test
-- that drives two specific processDay calls and diffs its OWN two captured
-- values (see selftest below), not in hidden state verify() cannot know is
-- stale relative to a reset it was never told about.
-- ============================================================================
function TownEconomy.verify()
    local v = {}
    local settlements = WSM.get("settlements")
    for key, town in pairs(settlements) do
        if town.specialty then
            if not SPECIALTY_RESOURCE[town.specialty] then
                v[#v + 1] = ("[INV1] %s has unknown specialty %s"):format(key, tostring(town.specialty))
            end
            local stock = town.stock or {}
            for _, res in ipairs(RESOURCES) do
                if stock[res] == nil then
                    v[#v + 1] = ("[INV2] %s stock missing %s"):format(key, res)
                elseif type(stock[res]) ~= "number" or stock[res] < 0 then
                    v[#v + 1] = ("[INV3] %s stock.%s = %s"):format(key, res, tostring(stock[res]))
                end
            end
        end
    end
    return v
end

-- ---------------------------------------------------------------------------
function TownEconomy.report()
    local settlements = WSM.get("settlements")
    for key, town in pairs(settlements) do
        if town.specialty then
            local s = town.stock or freshStock()
            log(("%-16s specialty=%-8s stone=%-4d iron=%-4d copper=%-4d food=%-4d")
                :format(key, town.specialty, s.stone, s.iron, s.copper, s.food))
        end
    end
end

-- ---------------------------------------------------------------------------
function TownEconomy.selftest()
    local passed, failed = 0, 0
    local function check(name, cond, detail)
        if cond then passed = passed + 1
        else failed = failed + 1 log("  FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
    end

    WSM.reset()

    check("register refuses unknown specialty", TownEconomy.registerTown("Squin", "gold") == false)
    check("register accepts iron", TownEconomy.registerTown("Squin", "iron") == true)
    check("register accepts copper", TownEconomy.registerTown("Sho-Battai", "copper") == true)
    check("register accepts farming", TownEconomy.registerTown("Admag", "farming") == true)

    -- disabled: direct call must report not-ready and change nothing
    TownEconomy.setCvar("kos.town.specialty.enable", 0)
    check("disabled processDay returns false (not ready)", TownEconomy.processDay(1) == false)
    check("disabled: stock unchanged", TownEconomy.stockOf("Squin").iron == 0)

    -- enabled: one direct day of production
    --
    -- SNAPSHOT SCALARS, NOT THE TABLE. stockOf() correctly returns the live
    -- WSM table (same "never a snapshot" contract WSM.get() itself documents
    -- -- Storage/Items follow it too), so holding the returned table across a
    -- later processDay() call and comparing it to a second stockOf() call
    -- compares the SAME mutated table to itself. First draft did exactly
    -- that and the "second day strictly increases" check below failed for
    -- the wrong reason -- pull the numbers out into locals immediately.
    TownEconomy.setCvar("kos.town.specialty.enable", 1)
    check("enabled processDay returns true", TownEconomy.processDay(1) == true)
    local squin1 = TownEconomy.stockOf("Squin")
    local stone1, iron1, copper1, food1 = squin1.stone, squin1.iron, squin1.copper, squin1.food
    check("baseline stone produced everywhere", stone1 == CFG.baseStonePerDay)
    check("specialty resource produced at the high rate", iron1 == CFG.specialtyPerDay)
    check("off-specialty resources produced at the trace rate",
          copper1 == CFG.offSpecialtyPerDay and food1 == CFG.offSpecialtyPerDay)

    -- THE class-fantasy property: a town's specialty output must be
    -- materially higher than another town's off-specialty output of the same
    -- resource, not just statistically different (the FishTable.selftest()
    -- assertion shape, one system over).
    local shoBattaiIron1 = TownEconomy.stockOf("Sho-Battai").iron
    check("specialty output dwarfs another town's off-specialty output of the same resource",
          iron1 > shoBattaiIron1 * 3,
          ("squin.iron=%d shoBattai.iron=%d"):format(iron1, shoBattaiIron1))

    -- Regression-shaped, not a standing invariant (see the note above
    -- TownEconomy.verify): two SPECIFIC calls, diffed locally, prove
    -- production only ever adds -- without keeping cross-call state verify()
    -- could later find stale after an unrelated WSM.reset().
    TownEconomy.processDay(2)
    local squin2 = TownEconomy.stockOf("Squin")
    check("a second direct day strictly increases every resource",
          squin2.stone > stone1 and squin2.iron > iron1
          and squin2.copper > copper1 and squin2.food > food1)

    -- WSM.catchUp integration. First-ever call for a new key adopts the
    -- current day as baseline and does NO work -- WSM.catchUp's own
    -- documented contract, exercised here for the first time by a real
    -- caller instead of only WSM's synthetic selftest handler.
    local firstRun = TownEconomy.catchUpTo(10)
    check("first catchUp call adopts baseline, runs nothing yet", firstRun == 0)

    WSM.advanceDay(4)
    local ran = TownEconomy.catchUpTo(10)
    check("catchUp ran exactly the days that had elapsed", ran == 4, ran)
    -- 2 direct calls + 4 catchUp days = 6 production cycles so far
    check("stone reflects all cycles run so far (direct + catchUp)",
          TownEconomy.stockOf("Squin").stone == CFG.baseStonePerDay * 6,
          TownEconomy.stockOf("Squin").stone)

    -- Disabling mid-stream must not lose or fabricate days: catchUp reports
    -- 0 ran while off (the watermark does not move), and resumes exactly
    -- where it left off once re-enabled.
    TownEconomy.setCvar("kos.town.specialty.enable", 0)
    WSM.advanceDay(3)
    local ranWhileOff = TownEconomy.catchUpTo(10)
    check("catchUp runs nothing while disabled", ranWhileOff == 0)
    TownEconomy.setCvar("kos.town.specialty.enable", 1)
    local resumed = TownEconomy.catchUpTo(10)
    check("catchUp resumes and catches up exactly the days missed while disabled", resumed == 3, resumed)
    check("stone reflects every cycle: 2 direct + 4 + 3 catchUp days = 9",
          TownEconomy.stockOf("Squin").stone == CFG.baseStonePerDay * 9,
          TownEconomy.stockOf("Squin").stone)

    check("invariants clean after normal operation", #TownEconomy.verify() == 0)

    -- Prove the invariant contract actually checks, not just documents.
    WSM.mutate("settlements", function(s)
        s["__badtown__"] = { specialty = "not-a-real-thing", stock = freshStock() }
    end, "test")
    local viol = TownEconomy.verify()
    local sawInv1 = false
    for _, m in ipairs(viol) do if m:find("INV1") then sawInv1 = true end end
    check("verify catches an unknown specialty", sawInv1)
    WSM.mutate("settlements", function(s) s["__badtown__"] = nil end, "test")

    WSM.reset()
    log(("--- SELFTEST: %d passed, %d failed ---"):format(passed, failed))
    return failed == 0
end

log("20_town_economy loaded -- TownEconomy.registerTown / .processDay / .catchUpTo / .report / .selftest()")
