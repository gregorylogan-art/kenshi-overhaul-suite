-- ============================================================================
-- Kenshi Overhaul Suite -- RUMOR PIPELINE  (#29 Taverns / #33 Alive Core)
--
-- "event -> rumor pipeline (WSM history -> tavern talk)" is listed as shared
-- infrastructure under BOTH Taverns and Alive Core -- built once here rather
-- than risking two subtly different copies later. Zero FCS dependency, zero
-- NPC-autonomy dependency (no addJob/addOrder/addGoal anywhere in this
-- file) -- unlike most of the remaining roadmap, this needed nothing from
-- the Projector probe (#34) to start.
--
-- WHAT THIS ACTUALLY DOES -- read before assuming more. WSM.queryHistory()
-- rows carry only {day, hour, category, source} (Rule 6's event history is a
-- conservation/audit trail, not a narrative log -- see 05_wsm.lua). So a
-- "rumor" here is NOT "Bob sold 4 fish to the Squin dock at 3pm" -- that
-- detail was never logged anywhere. What IS honestly derivable:
--   * CURRENT STATE flavor, templated over TownEconomy's stock/specialty and
--     Economy's vendor floats/earnings -- real numbers, just not a narrative
--     of how they got there.
--   * ACTIVITY-LEVEL flavor from WSM.queryHistory -- "how many economy-
--     category mutations happened in the last N days" is a coarse but
--     genuine "the town's been busy" signal, the one thing queryHistory
--     actually answers.
-- A future session should not build TOWARD richer rumors by assuming this
-- reads event detail it does not have -- that would need WorldEvents-style
-- structured logging (WSM.state.events, currently an unused stub category)
-- built out first, not a rumor generator pretending it already exists.
--
-- CONTRACT
--     Rumor.generate()   -> string[]   one line per rumor; may be empty
--     Rumor.tell()        -> nil        prints generate() (screen label later,
--                                        once a tavern/dialogue trigger exists)
--     Rumor.selftest()    -> boolean
-- ============================================================================

local TAG = "[RUMOR] "
local function log(m) print(TAG .. tostring(m)) end

Rumor = Rumor or {}
pcall(function() _G.Rumor = Rumor end)

-- ---------------------------------------------------------------------------
-- Config -- thresholds, not magic numbers scattered through the generators.
-- ---------------------------------------------------------------------------
local CFG = {
    -- TownEconomy stock read as "doing well" once this many units of the
    -- town's specialty resource have piled up (CFG.specialtyPerDay in
    -- 20_town_economy.lua is 5/day, so 20 is ~4 days of specialty production
    -- -- enough to read as an accumulating surplus, not one lucky day).
    specialtySurplus = 20,
    -- Vendor float read as "broke" / "flush" at these thresholds. No
    -- authoritative source for what a "normal" float is yet (no real vendor
    -- has been played through), so these are placeholders -- tune once a
    -- live economy actually runs for a while.
    vendorBroke      = 20,
    vendorFlush      = 500,
    -- "Busy" activity-level threshold: economy-category WSM mutations in the
    -- lookback window.
    busyMutations    = 5,
    lookbackDays     = 3,
}

-- Multiple phrasings per rumor TYPE so two calls back to back do not read as
-- a fill-in-the-blank template -- the same reason FishTable spreads weight
-- across a table instead of a single fixed roll.
local TEMPLATES = {
    specialtySurplus = {
        "Word is %s is doing well in %s these days.",
        "Heard %s has %s coming out of their ears.",
        "%s's %s trade is booming, or so they say.",
    },
    resourceShort = {
        "Heard %s is running short on %s.",
        "%s could use more %s, from what I've heard.",
    },
    vendorFlush = {
        "The shop at %s is flush with cats lately.",
        "Word is %s's coffers are looking healthy.",
    },
    vendorBroke = {
        "Heard the vendor at %s is nearly out of coin.",
        "%s's shop is running on empty, they say.",
    },
    busy = {
        "Things have been busy in town lately.",
        "Lot of trading going on these days.",
    },
    quiet = {
        "It's been quiet around here lately.",
        "Not much happening in town, from what I hear.",
    },
}

local function pick(list)
    return list[math.random(#list)]
end

-- ---------------------------------------------------------------------------
-- Rumor.generate -- pure-ish: reads WSM/Economy/TownEconomy state, writes
-- nothing, no engine calls. Fully headless-testable.
-- ---------------------------------------------------------------------------
function Rumor.generate()
    local out = {}

    -- Town specialty flavor (TownEconomy, #48).
    if TownEconomy then
        local settlements = WSM and WSM.get and WSM.get("settlements") or {}
        for townKey, town in pairs(settlements) do
            if town.specialty and town.stock then
                local specialtyRes = ({ iron = "iron", copper = "copper", farming = "food" })[town.specialty]
                if specialtyRes then
                    local amount = town.stock[specialtyRes] or 0
                    if amount >= CFG.specialtySurplus then
                        out[#out + 1] = pick(TEMPLATES.specialtySurplus):format(townKey, town.specialty)
                    end
                    -- A non-specialty resource sitting near zero reads as a
                    -- genuine shortage -- TownEconomy's off-specialty trickle
                    -- rate means it should never be exactly 0 for long once
                    -- any days have run, so 0 specifically is informative.
                    for _, res in ipairs({ "stone", "iron", "copper", "food" }) do
                        if res ~= specialtyRes and (town.stock[res] or 0) == 0 then
                            out[#out + 1] = pick(TEMPLATES.resourceShort):format(townKey, res)
                        end
                    end
                end
            end
        end
    end

    -- Vendor economy flavor (Economy, #28/#50).
    if Economy and Economy.vendors then
        for vendorKey, vendor in pairs(Economy.vendors) do
            if vendor.float >= CFG.vendorFlush then
                out[#out + 1] = pick(TEMPLATES.vendorFlush):format(vendorKey)
            elseif vendor.float <= CFG.vendorBroke then
                out[#out + 1] = pick(TEMPLATES.vendorBroke):format(vendorKey)
            end
        end
    end

    -- Activity-level flavor (WSM.queryHistory -- the one thing it can
    -- honestly answer: HOW MUCH, not WHAT/WHO).
    --
    -- BUG FOUND IN THE FIRST LIVE RUN (2026-08-10): this only checked the
    -- "economy" category (Economy.lua's vendor sell/mint/drain), so
    -- TownEconomy's daily production -- which writes to "settlements", a
    -- DIFFERENT category -- could never register as "busy" no matter how
    -- much town production ran. Both now count; "activity" means either kind
    -- of thing happening, not specifically money changing hands.
    if WSM and WSM.queryHistory and WSM.day then
        local sinceDay = WSM.day() - CFG.lookbackDays
        local econRecent = WSM.queryHistory({ category = "economy", sinceDay = sinceDay })
        local townRecent = WSM.queryHistory({ category = "settlements", sinceDay = sinceDay })
        local total = #econRecent + #townRecent
        if total >= CFG.busyMutations then
            out[#out + 1] = pick(TEMPLATES.busy)
        elseif total == 0 then
            out[#out + 1] = pick(TEMPLATES.quiet)
        end
    end

    return out
end

-- Rumor.tell() -- console output today. Once a tavern/dialogue trigger
-- exists (#29), this is the function it calls; screen-label/dialogue-text
-- routing is a presentation change at that call site, not a rewrite here.
function Rumor.tell()
    local lines = Rumor.generate()
    if #lines == 0 then
        log("no rumors right now -- nothing notable in town/vendor state")
        return
    end
    for _, line in ipairs(lines) do log(line) end
end

-- ---------------------------------------------------------------------------
function Rumor.selftest()
    local passed, failed = 0, 0
    local function check(name, cond, detail)
        if cond then passed = passed + 1
        else failed = failed + 1 log("  FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
    end

    check("generate() returns a table with no state at all", type(Rumor.generate()) == "table")

    if WSM and TownEconomy then
        WSM.reset()
        TownEconomy.setCvar("kos.town.specialty.enable", 1)
        TownEconomy.registerTown("__rumortest_iron__", "iron")
        for _ = 1, 5 do TownEconomy.processDay(1) end   -- 5 days: iron = 25 >= surplus threshold (20)

        local lines = Rumor.generate()
        local sawSurplus = false
        for _, l in ipairs(lines) do
            if l:find("__rumortest_iron__") and l:find("iron") then sawSurplus = true end
        end
        check("specialty surplus produces a rumor naming the town and resource", sawSurplus,
              table.concat(lines, " | "))

        -- A town with NO specialty must never generate a rumor -- nil
        -- specialty must not crash the resource lookup.
        WSM.mutate("settlements", function(s)
            s["__rumortest_nospecialty__"] = { stock = { stone = 1, iron = 0, copper = 0, food = 0 } }
        end, "test")
        local ok = pcall(Rumor.generate)
        check("a settlement with no specialty does not error", ok)

        WSM.reset()
    end

    if Economy then
        Economy.vendors, Economy.earnings, Economy.minted, Economy.mintLog = {}, {}, 0, {}
        Economy.registerVendor("__rumortest_vendor__", 0)
        Economy.mint("__rumortest_vendor__", 1000, "test")
        local lines = Rumor.generate()
        local sawFlush = false
        for _, l in ipairs(lines) do if l:find("__rumortest_vendor__") then sawFlush = true end end
        check("a flush vendor produces a rumor naming it", sawFlush, table.concat(lines, " | "))

        Economy.drain("__rumortest_vendor__", Economy.floatOf("__rumortest_vendor__"), "test")
        local lines2 = Rumor.generate()
        local sawBroke = false
        for _, l in ipairs(lines2) do if l:find("__rumortest_vendor__") then sawBroke = true end end
        check("a broke vendor also produces a rumor naming it (different template)", sawBroke,
              table.concat(lines2, " | "))

        Economy.vendors, Economy.earnings, Economy.minted, Economy.mintLog = {}, {}, 0, {}
    end

    if WSM then
        WSM.reset()
        local quietLines = Rumor.generate()
        local sawQuiet = false
        for _, l in ipairs(quietLines) do
            for _, t in ipairs(TEMPLATES.quiet) do if l == t then sawQuiet = true end end
        end
        check("no recent activity produces a 'quiet' rumor", sawQuiet, table.concat(quietLines, " | "))

        for i = 1, CFG.busyMutations do
            WSM.mutate("economy", function() end, "test" .. i)
        end
        local busyLines = Rumor.generate()
        local sawBusy = false
        for _, l in ipairs(busyLines) do
            for _, t in ipairs(TEMPLATES.busy) do if l == t then sawBusy = true end end
        end
        check("enough recent activity produces a 'busy' rumor instead", sawBusy, table.concat(busyLines, " | "))

        -- REGRESSION for the live-run bug (2026-08-10): "settlements"-only
        -- activity (TownEconomy's shape, not Economy's) must ALSO count as
        -- busy -- the first shipped version only checked "economy" and never
        -- saw town production no matter how much of it ran.
        WSM.reset()
        for i = 1, CFG.busyMutations do
            WSM.mutate("settlements", function() end, "test" .. i)
        end
        local townBusyLines = Rumor.generate()
        local sawTownBusy = false
        for _, l in ipairs(townBusyLines) do
            for _, t in ipairs(TEMPLATES.busy) do if l == t then sawTownBusy = true end end
        end
        check("settlements-only activity ALSO produces a 'busy' rumor (the live-run bug)",
              sawTownBusy, table.concat(townBusyLines, " | "))

        WSM.reset()
    end

    check("tell() does not error with nothing loaded", pcall(Rumor.tell))

    log(("--- SELFTEST: %d passed, %d failed ---"):format(passed, failed))
    return failed == 0
end

log("22_rumor loaded -- Rumor.generate() / .tell() / .selftest()")
