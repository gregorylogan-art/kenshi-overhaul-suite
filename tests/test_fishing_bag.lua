-- ============================================================================
-- CHARACTERIZATION TESTS -- fishing's catch bag
--
-- Written BEFORE migrating fishing onto the shared Items layer, and deliberately
-- so. These pin the behaviour that is currently LIVE-VERIFIED (Greg fished 100+
-- items through it without a freeze), so the migration has something to be
-- measured against instead of "it looked fine".
--
-- A characterization test asserts what the code DOES, not what it should do.
-- If the migration changes any of these, that is a behaviour change to justify
-- out loud -- not a test to quietly update.
--
-- The one thing not covered here is the engine path inside collect(): minting
-- needs a real Character. That boundary is exactly why the migration still
-- wants a live run before it is called done.
-- ============================================================================

local T = { passed = 0, failed = 0, names = {} }
local function check(name, cond, detail)
    if cond then T.passed = T.passed + 1
    else
        T.failed = T.failed + 1
        T.names[#T.names + 1] = name .. (detail and ("  -- " .. tostring(detail)) or "")
    end
end

if not _G.Fishing then
    print("--- FISHING BAG: skipped, Fishing not loaded ---")
    return true
end

-- Fishing keys state by character NAME, and stateFor() is a local, so drive the
-- public surface the same way the game does: through Fishing.state.
local NAME = "__bagtest__"
if _G.Items then Items.bags[NAME], Items.counts[NAME], Items.ledger[NAME] = nil, nil, nil end
Fishing.state[NAME] = nil
local s = Fishing.state[NAME]
if not s then
    s = { casting = false, elapsed = 0, caught = 0, garbage = 0 }
    Fishing.state[NAME] = s
end

-- --- how banking accumulates ------------------------------------------------
-- Calls the REAL migrated entry point rather than replicating its body. A test
-- that reimplements the code it checks passes happily while the shipped path
-- rots underneath it -- which is exactly the failure mode that let an inert
-- skill model sit unnoticed for a session.
local function bank(itemId) return Fishing.bankItem(NAME, itemId) end
local function bagNow() return Fishing.bagFor(NAME) end

-- Clear whichever store is live (shared ledger post-migration, private bag
-- before it), so the test is valid on both sides of the change.
if _G.Items then
    Items.bags[NAME], Items.counts[NAME], Items.ledger[NAME] = nil, nil, nil
end
s.bag, s.bagCount = nil, nil

bank("Small Fish")
bank("Small Fish")
bank("Book")
local bag0, count0 = bagNow()
check("bag: counts per item", bag0["Small Fish"] == 2 and bag0["Book"] == 1)
check("bag: total tracks separately", count0 == 3)
check("bag: routed through the shared ledger", _G.Items == nil or
      (Items.counts[NAME] or 0) == 3,
      "post-migration this must land in Items, not a private table")

-- --- the collect drain loop -------------------------------------------------
-- Mirrors Fishing.collect (~1301) with the engine mint stubbed to succeed, so
-- the BOOKKEEPING is tested without needing a Character.
-- Drains through Items.take when the shared ledger is live, so the drain uses
-- the same bookkeeping the real collect() does; falls back to the private bag
-- only if Items is absent.
local function drain(grantSucceeds)
    local moved, stoppedOn = 0, nil
    local bag = bagNow()
    local order = {}
    for id in pairs(bag) do order[#order + 1] = id end
    for _, id in ipairs(order) do
        local n = select(1, bagNow())[id] or 0
        for _ = 1, n do
            if not grantSucceeds(id) then stoppedOn = "no room" break end
            if _G.Items then Items.take(NAME, id, 1)
            else
                s.bag[id] = s.bag[id] - 1
                s.bagCount = s.bagCount - 1
                if s.bag[id] == 0 then s.bag[id] = nil end
            end
            moved = moved + 1
        end
        if stoppedOn then break end
    end
    return moved, stoppedOn
end

local moved = drain(function() return true end)
local bagAfter, countAfter = bagNow()
check("collect: moves everything when the pack accepts", moved == 3)
check("collect: bag count reaches zero", countAfter == 0, countAfter)
check("collect: emptied rows are removed", next(bagAfter) == nil)

-- --- partial collect: the full-pack case ------------------------------------
-- This is the behaviour that matters most. A refusal must keep the remainder
-- BANKED rather than dropping it, or a full pack silently destroys the catch.
bank("Small Fish") bank("Small Fish") bank("Small Fish")
local allowed = 1
local movedPartial, stopped = drain(function()
    if allowed > 0 then allowed = allowed - 1 return true end
    return false
end)
check("collect: stops at the first refusal", movedPartial == 1, movedPartial)
check("collect: reports why", stopped == "no room")
local bagPart, countPart = bagNow()
check("collect: REMAINDER STAYS BANKED", countPart == 2, countPart)
check("collect: nothing was destroyed", (bagPart["Small Fish"] or 0) == 2)

-- --- conservation across the whole cycle ------------------------------------
if _G.Items then Items.bags[NAME], Items.counts[NAME], Items.ledger[NAME] = nil, nil, nil end
s.bag, s.bagCount = nil, nil
local banked = 0
for i = 1, 25 do
    bank(i % 3 == 0 and "Book" or "Small Fish")
    banked = banked + 1
end
local bagCycle, countCycle = bagNow()
check("cycle: banked count is exact", countCycle == banked, countCycle)
local sum = 0
for _, n in pairs(bagCycle) do sum = sum + n end
check("cycle: rows sum to the cached count", sum == countCycle, sum .. " vs " .. countCycle)

local movedAll = drain(function() return true end)
local bagEnd, countEnd = bagNow()
check("cycle: everything collected", movedAll == banked, movedAll)
check("cycle: nothing left over", countEnd == 0 and next(bagEnd) == nil)

-- --- the shared layer must agree ---------------------------------------------
-- Same sequence through Items. If these diverge, the migration would change
-- behaviour, and this is where that shows up.
if _G.Items then
    local KEY = "__bagtest_items__"
    Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil
    for i = 1, 25 do
        Items.bank(KEY, i % 3 == 0 and "Book" or "Small Fish", 1)
    end
    local ibag, icount = Items.bagOf(KEY)
    check("parity: Items totals match fishing's", icount == banked, icount)
    check("parity: Items per-item matches", ibag["Book"] == 8 and ibag["Small Fish"] == 17,
          tostring(ibag["Book"]) .. "/" .. tostring(ibag["Small Fish"]))
    check("parity: Items invariants clean", #Items.verify() == 0)
    Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil
end

if _G.Items then Items.bags[NAME], Items.counts[NAME], Items.ledger[NAME] = nil, nil, nil end
Fishing.state[NAME] = nil

print(("--- FISHING BAG: %d passed, %d failed ---"):format(T.passed, T.failed))
for _, n in ipairs(T.names) do print("    FAILED: " .. n) end
if T.failed > 0 then error("fishing bag characterization failed", 0) end
return true
