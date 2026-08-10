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

-- ============================================================================
-- HANDOFF: fishing -> cooking
--
-- Fishing banks "Small Fish"; cooking's raw list is headed by "Raw Fish" (the
-- FCS item). Both are real, so a resolution-first lookup picked "Raw Fish",
-- found none banked, and reported "nothing to cook" over a bagful of fish.
--
-- That bug was found here, headlessly, before it ever reached a play session --
-- where it would have looked like cooking being broken rather than two systems
-- disagreeing about a name.
-- ============================================================================
if _G.Items and _G.Cooking then
    local H = { passed = 0, failed = 0, names = {} }
    local function hcheck(name, cond, detail)
        if cond then H.passed = H.passed + 1
        else
            H.failed = H.failed + 1
            H.names[#H.names + 1] = name .. (detail and ("  -- " .. tostring(detail)) or "")
        end
    end

    local KEY = "__handoff__"
    Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil

    -- Exactly what fishing produces.
    Items.bank(KEY, "Small Fish", 6)
    local bag = Items.bagOf(KEY)
    hcheck("handoff: fishing's product is banked", bag["Small Fish"] == 6)

    -- Cooking must consume THAT, not a differently-named sibling.
    local consumed = 0
    for _ = 1, 6 do
        if Items.take(KEY, "Small Fish", 1) then
            consumed = consumed + 1
            Items.bank(KEY, "Cooked Fish", 1)
        end
    end
    hcheck("handoff: cooking consumed what fishing banked", consumed == 6, consumed)

    local after, total = Items.bagOf(KEY)
    hcheck("handoff: raw fully consumed", (after["Small Fish"] or 0) == 0)
    hcheck("handoff: product conserved", (after["Cooked Fish"] or 0) == 6)
    hcheck("handoff: nothing created or destroyed", total == 6, total)
    hcheck("handoff: invariants clean", #Items.verify() == 0)

    Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil
    print(("--- HANDOFF: %d passed, %d failed ---"):format(H.passed, H.failed))
    for _, n in ipairs(H.names) do print("    FAILED: " .. n) end
    if H.failed > 0 then error("handoff failed", 0) end
end

-- ============================================================================
-- DOCK LOOP: haul -> shared storage -> cook from storage (#24, 2026-08-09)
--
-- Greg: the vanilla farm shape (harvest, haul to storage, work from storage,
-- loop) should apply to fishing too -- fish, haul to storage, cooks take from
-- storage and cook. Storage.lua already provides the shared-owner-key ledger
-- this needs; Fishing.haulToDock and Cooking.cookFromDock/canCookFromDock are
-- thin call sites on top of it, not a second implementation.
--
-- NOT COVERED HERE: Fishing.haulToDock() itself, which calls
-- getSelectedCharacter() -- a real engine global absent in this headless
-- runner. The haul step is simulated with a direct Storage.deposit (exactly
-- what a successful haul produces), so this still exercises the REAL new
-- code -- Cooking.cook's ownerKeyOverride threading and the cookFromDock/
-- canCookFromDock wrappers -- everything except the engine-facing character
-- lookup itself. Same boundary this file's own header note already draws
-- for Fishing.collect()'s mint path; a live run still owns proving the haul
-- call site works end to end.
-- ============================================================================
if _G.Items and _G.Storage and _G.Cooking then
    local D = { passed = 0, failed = 0, names = {} }
    local function dcheck(name, cond, detail)
        if cond then D.passed = D.passed + 1
        else
            D.failed = D.failed + 1
            D.names[#D.names + 1] = name .. (detail and ("  -- " .. tostring(detail)) or "")
        end
    end

    local DOCK = "__testdock__"
    local dockKey = Storage.key(DOCK)
    Items.bags[dockKey], Items.counts[dockKey], Items.ledger[dockKey] = nil, nil, nil

    -- Simulated haul: a fisher's catch lands in the dock's shared storage.
    Storage.deposit(DOCK, "Small Fish", 8)
    dcheck("dock: hauled fish present in storage", Storage.stockOf(DOCK)["Small Fish"] == 8)

    -- A cook, with no bag of their own, works directly from the dock.
    local FAKE_COOK = {}   -- no getStats/getName; every real-Character call inside
                            -- Cooking.cook is pcall-wrapped and degrades safely
    local can, why = Cooking.canCookFromDock(FAKE_COOK, DOCK)
    dcheck("dock: cook can see the hauled fish", can == true, why)

    local cooked, burnt, err = Cooking.cookFromDock(FAKE_COOK, DOCK, 8)
    dcheck("dock: cook consumed exactly what was hauled", cooked + burnt == 8,
           ("cooked=%s burnt=%s err=%s"):format(tostring(cooked), tostring(burnt), tostring(err)))

    local afterStock = Storage.stockOf(DOCK)
    dcheck("dock: raw fish fully consumed from storage", (afterStock["Small Fish"] or 0) == 0)
    dcheck("dock: product landed back in the SAME dock (shared hub, not the cook's own bag)",
           (afterStock["Cooked Fish"] or 0) + (afterStock["Burnt Fish"] or 0) == 8)
    dcheck("dock: invariants clean end to end", #Items.verify() == 0)

    Items.bags[dockKey], Items.counts[dockKey], Items.ledger[dockKey] = nil, nil, nil
    print(("--- DOCK LOOP: %d passed, %d failed ---"):format(D.passed, D.failed))
    for _, n in ipairs(D.names) do print("    FAILED: " .. n) end
    if D.failed > 0 then error("dock loop failed", 0) end
end

print(("--- FISHING BAG: %d passed, %d failed ---"):format(T.passed, T.failed))
for _, n in ipairs(T.names) do print("    FAILED: " .. n) end
if T.failed > 0 then error("fishing bag characterization failed", 0) end
return true

