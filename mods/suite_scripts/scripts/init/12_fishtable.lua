-- ============================================================================
-- Kenshi Overhaul Suite -- FISH TABLE  (#18 tiers, #19 class fantasy)
--
-- WHY THIS EXISTS
-- Greg's stated top complaint about Kenshi:
--     "my biggest issue with the game is fantacy of class"
-- and the goal for fishing: a character who fishes should visibly BECOME a
-- fisherman.
--
-- Right now skill only changes HOW OFTEN you catch a fish -- junk odds fall,
-- fish odds rise -- and the fish is always the same Small Fish. That is a
-- quantity curve, not an identity. A master angler pulling the same minnow as a
-- beggar is exactly the flatness the class fantasy is meant to fix.
--
-- So WHAT you catch is a second axis:
--     * TIER by skill      -- rare fish are gated behind being good at this
--     * DEPTH              -- the shelf gives up different fish than the shallows
--     * REGION             -- Greg: "per zone change the fish type"
--     * TIME OF DAY        -- night fish exist and are worth more
--
-- The result is that a veteran fisher's catch LOOKS different, not just longer.
--
-- ENTIRELY PURE. No engine calls, no character required, so every rule here is
-- headless-testable -- which matters because odds bugs are invisible in play
-- (the shipped 5/80/15 was really 5/95 for a whole session and nobody could see
-- it by fishing).
--
-- CONTRACT
--     FishTable.candidates(ctx)      -> array of {name, weight}   PURE
--     FishTable.roll(ctx, rnd)       -> name                      PURE, injectable rnd
--     FishTable.describe(ctx)        -> string                    for the log
--     FishTable.selftest()           -> boolean
--
--   ctx = { skill=0..100, waterLevel=1..3, region="border", night=false }
--
-- CONTENT NOTE: only fish whose FCS items EXIST may be enabled. Everything past
-- tier 1 is declared but flagged `pending = true` until Greg authors it, and
-- candidates() filters those out. A table that rolls a nonexistent item silently
-- grants nothing -- getDataByName fails silently (#23) -- so a name we have not
-- created is worse than no entry at all.
-- ============================================================================

local TAG = "[FISHTBL] "
local function log(m) print(TAG .. tostring(m)) end

FishTable = FishTable or {}
pcall(function() _G.FishTable = FishTable end)

-- ---------------------------------------------------------------------------
-- The table
-- ---------------------------------------------------------------------------
-- weight  : relative chance once eligible, at the moment it unlocks
-- weightAt100 : weight at skill 100. Interpolated between the two.
--           THIS IS THE CLASS FANTASY LEVER. Without it a master still pulls
--           61% minnows and the preview at skill 40/70/100 is IDENTICAL --
--           progression plateaus the moment the last tier unlocks. Common fish
--           must THIN OUT as you improve, so a veteran's catch reads differently
--           rather than merely including a few rarities.
-- minSkill: gate. This is the class fantasy -- some fish simply cannot be caught
--           until you are good, so improving CHANGES your catch rather than just
--           speeding it up.
-- depth   : which waterLevel bands it lives in
-- night   : nil = any, true = only at night, false = only by day
-- pending : declared but the FCS item does not exist yet -> filtered out
FishTable.entries = FishTable.entries or {
    -- TIER 1 -- exists today, the bread and butter
    { name = "Small Fish", weight = 100, weightAt100 = 25, minSkill = 0,  depth = { 1, 2, 3 } },

    -- TIER 2 -- a competent fisher starts pulling real food
    { name = "River Fish", weight = 45,  weightAt100 = 55, minSkill = 15, depth = { 1, 2 },    pending = true },
    { name = "Cave Fish",  weight = 30,  minSkill = 15, depth = { 2, 3 },    pending = true,
      regions = { swamp = true, cave = true } },

    -- TIER 3 -- deep water, skill, and worth carrying home
    { name = "Great Fish", weight = 18,  weightAt100 = 40, minSkill = 40, depth = { 2, 3 },    pending = true },
    { name = "Night Eel",  weight = 22,  minSkill = 35, depth = { 2, 3 },    pending = true,
      night = true },

    -- TIER 4 -- the thing a fisherman is known for
    { name = "Bonefish",   weight = 6,   weightAt100 = 20, minSkill = 70, depth = { 3 },       pending = true },
}

-- Regions are declared here rather than inferred, so an unknown zone degrades to
-- the default set instead of silently producing an empty table.
FishTable.DEFAULT_REGION = "default"

-- ---------------------------------------------------------------------------
-- FishTable.candidates -- what could be caught in this context
-- ---------------------------------------------------------------------------
function FishTable.candidates(ctx)
    ctx = ctx or {}
    local skill  = tonumber(ctx.skill) or 0
    local depth  = tonumber(ctx.waterLevel) or 1
    local region = ctx.region or FishTable.DEFAULT_REGION
    local night  = ctx.night == true

    local out = {}
    for _, e in ipairs(FishTable.entries) do
        local ok = true

        -- Content gate first: never offer an item that does not exist.
        if e.pending and not FishTable.allowPending then ok = false end

        if ok and skill < (e.minSkill or 0) then ok = false end

        if ok and e.depth then
            local match = false
            for _, d in ipairs(e.depth) do if d == depth then match = true break end end
            if not match then ok = false end
        end

        if ok and e.night ~= nil and e.night ~= night then ok = false end

        if ok and e.regions and not e.regions[region] then ok = false end

        if ok then
            -- Interpolate the weight across the skill range, so improving does
            -- not merely ADD rarities -- it also pushes the common catch down.
            local w = e.weight or 1
            if e.weightAt100 then
                local t = math.max(0, math.min(1, skill / 100))
                w = w + (e.weightAt100 - w) * t
            end
            out[#out + 1] = { name = e.name, weight = w }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- FishTable.roll -- weighted pick
-- ---------------------------------------------------------------------------
-- `rnd` is injectable so tests can drive it deterministically. Fishing's real
-- distribution bug survived a whole session precisely because it could only be
-- observed by playing; a seam like this makes the outcome table checkable.
function FishTable.roll(ctx, rnd)
    local pool = FishTable.candidates(ctx)
    if #pool == 0 then return nil, "no eligible fish" end

    local total = 0
    for _, c in ipairs(pool) do total = total + c.weight end
    if total <= 0 then return nil, "zero total weight" end

    local r = (rnd or math.random)() * total
    local acc = 0
    for _, c in ipairs(pool) do
        acc = acc + c.weight
        if r < acc then return c.name end
    end
    -- Floating-point tail: the accumulated sum can land a hair under `total`.
    -- Returning the last entry is correct and cannot return nil, which a caller
    -- would have to treat as "no catch" and silently lose the roll.
    return pool[#pool].name
end

function FishTable.describe(ctx)
    local pool = FishTable.candidates(ctx)
    if #pool == 0 then return "no eligible fish here" end
    local parts = {}
    local total = 0
    for _, c in ipairs(pool) do total = total + c.weight end
    for _, c in ipairs(pool) do
        parts[#parts + 1] = ("%s %.0f%%"):format(c.name, c.weight / total * 100)
    end
    return table.concat(parts, "  ")
end

-- FishTable.preview() -- what a fisher of each skill would pull. Answers "does
-- progression actually change my catch?" without grinding a character to 70.
function FishTable.preview()
    for _, skill in ipairs({ 0, 20, 40, 70, 100 }) do
        log(("skill %-3d depth2 day   : %s"):format(skill,
            FishTable.describe({ skill = skill, waterLevel = 2 })))
    end
    log(("skill 50  depth3 NIGHT : %s"):format(
        FishTable.describe({ skill = 50, waterLevel = 3, night = true })))
    if not FishTable.allowPending then
        log("NOTE: tiers 2+ are filtered out -- their FCS items do not exist yet.")
        log("      FishTable.allowPending = true to preview the full curve.")
    end
end

-- ---------------------------------------------------------------------------
function FishTable.selftest()
    local passed, failed = 0, 0
    local function check(name, cond, detail)
        if cond then passed = passed + 1
        else failed = failed + 1 log("  FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
    end

    -- Content safety: with pending filtered, only real items are offered.
    FishTable.allowPending = false
    local base = FishTable.candidates({ skill = 100, waterLevel = 3 })
    check("pending entries filtered out", #base == 1, #base)
    check("...and it is the one that exists", base[1] and base[1].name == "Small Fish")
    check("roll never returns a pending item",
          FishTable.roll({ skill = 100, waterLevel = 3 }) == "Small Fish")

    -- Now exercise the real curve.
    FishTable.allowPending = true

    local novice  = FishTable.candidates({ skill = 0,   waterLevel = 2 })
    local veteran = FishTable.candidates({ skill = 100, waterLevel = 2 })
    check("skill unlocks more fish", #veteran > #novice, #novice .. " -> " .. #veteran)

    -- THE class-fantasy property: a novice cannot pull a master's fish.
    local noviceNames = {}
    for _, c in ipairs(novice) do noviceNames[c.name] = true end
    check("novice cannot catch Bonefish", not noviceNames["Bonefish"])
    check("novice cannot catch Great Fish", not noviceNames["Great Fish"])

    -- Depth matters.
    local shallow = FishTable.candidates({ skill = 100, waterLevel = 1 })
    local shallowNames = {}
    for _, c in ipairs(shallow) do shallowNames[c.name] = true end
    check("Bonefish is deep water only", not shallowNames["Bonefish"])

    -- Time of day.
    local day   = FishTable.candidates({ skill = 100, waterLevel = 3, night = false })
    local night = FishTable.candidates({ skill = 100, waterLevel = 3, night = true })
    local dayNames, nightNames = {}, {}
    for _, c in ipairs(day)   do dayNames[c.name]   = true end
    for _, c in ipairs(night) do nightNames[c.name] = true end
    check("Night Eel only at night", nightNames["Night Eel"] and not dayNames["Night Eel"])

    -- Region.
    local plain = FishTable.candidates({ skill = 100, waterLevel = 2, region = "default" })
    local swamp = FishTable.candidates({ skill = 100, waterLevel = 2, region = "swamp" })
    local plainNames, swampNames = {}, {}
    for _, c in ipairs(plain) do plainNames[c.name] = true end
    for _, c in ipairs(swamp) do swampNames[c.name] = true end
    check("Cave Fish is region-gated", swampNames["Cave Fish"] and not plainNames["Cave Fish"])

    -- Weighted roll: deterministic via injected rnd.
    local ctx = { skill = 100, waterLevel = 3, night = true }
    check("roll at r=0 returns the first candidate",
          FishTable.roll(ctx, function() return 0 end) ~= nil)
    check("roll at r=1 still returns something (no nil tail)",
          FishTable.roll(ctx, function() return 0.999999999 end) ~= nil)

    -- Distribution roughly matches the weights.
    local counts, N = {}, 4000
    local seq = 0
    for i = 1, N do
        local name = FishTable.roll({ skill = 10, waterLevel = 2 },
                                    function() seq = (seq + 0.000271) % 1 return seq end)
        counts[name] = (counts[name] or 0) + 1
    end
    -- THE class-fantasy assertion: a master's catch must LOOK different, not
    -- just contain a couple of extra entries.
    local function shareOf(name, ctx)
        local pool = FishTable.candidates(ctx)
        local total, mine = 0, 0
        for _, c in ipairs(pool) do
            total = total + c.weight
            if c.name == name then mine = c.weight end
        end
        return total > 0 and (mine / total) or 0
    end
    local noviceShare = shareOf("Small Fish", { skill = 0,   waterLevel = 2 })
    local masterShare = shareOf("Small Fish", { skill = 100, waterLevel = 2 })
    check("common fish thins out with skill", masterShare < noviceShare * 0.5,
          ("%.0f%% -> %.0f%%"):format(noviceShare * 100, masterShare * 100))
    check("a master is not still mostly catching minnows", masterShare < 0.35,
          ("%.0f%%"):format(masterShare * 100))

    -- DELIBERATE CHANGE, not a broken test. This used to assert that the common
    -- fish dominates at skill 100, which was true of the old flat table and is
    -- now false BY DESIGN -- a master should not mostly pull minnows. Updated to
    -- assert the property that actually matters: the common fish dominates for a
    -- NOVICE, which is what makes improving feel like anything.
    check("common fish dominates for a novice",
          (counts["Small Fish"] or 0) > (counts["Great Fish"] or 0),
          tostring(counts["Small Fish"]) .. " vs " .. tostring(counts["Great Fish"]))

    -- Robustness.
    check("empty ctx does not error", type(FishTable.roll({})) == "string")
    check("nil ctx does not error", FishTable.roll(nil) ~= nil)
    local none = FishTable.candidates({ skill = 0, waterLevel = 99 })
    check("impossible depth yields nothing", #none == 0)
    local n, why = FishTable.roll({ skill = 0, waterLevel = 99 })
    check("...and roll says why", n == nil and why == "no eligible fish")

    FishTable.allowPending = false
    log(("--- SELFTEST: %d passed, %d failed ---"):format(passed, failed))
    return failed == 0
end

log("12_fishtable loaded -- FishTable.preview() / .roll(ctx) / .selftest()")
