-- ============================================================================
-- Kenshi Overhaul Suite -- STORAGE  (#24 docks, #30 camps)
--
-- The payoff of banking, beyond safety: a dock, a camp, a market and a character
-- are all just OWNER KEYS in the same ledger. Storage is `Items` with a
-- non-character owner, so conservation invariants apply to a warehouse for free
-- and there is no second stock system to drift out of agreement with the first.
--
-- The operation that actually matters is TRANSFER. Everything else is a rename
-- of an Items call, but moving goods between owners is where a stock system
-- duplicates or destroys things -- credit one side before debiting the other and
-- you have a duplication bug that looks like generosity.
--
-- CONTRACT
--     Storage.deposit(siteKey, itemName, n)              -> total
--     Storage.withdraw(siteKey, itemName, n)             -> ok
--     Storage.stockOf(siteKey)                           -> table, count
--     Storage.transfer(fromKey, toKey, itemName, n)      -> moved, reason
--     Storage.transferAll(fromKey, toKey)                -> moved
--     Storage.selftest()                                 -> boolean
--
-- SITE KEYS are namespaced so a site can never collide with a character name.
-- A character called "Dock" would otherwise share a bag with the dock itself,
-- which is the sort of thing that is obvious in hindsight and invisible in play.
-- ============================================================================

local TAG = "[STORE] "
local function log(m) print(TAG .. tostring(m)) end

Storage = Storage or {}
pcall(function() _G.Storage = Storage end)

Storage.PREFIX = "site:"

-- Site keys are namespaced; character keys are used bare, exactly as Fishing
-- and Cooking use them.
function Storage.key(siteName)
    return Storage.PREFIX .. tostring(siteName)
end

local function itemsOrNil()
    local ok, m = pcall(function() return _G.Items end)
    if ok and type(m) == "table" and type(m.bank) == "function" then return m end
    return nil
end

function Storage.deposit(siteKey, itemName, n)
    local I = itemsOrNil()
    if not I then return nil, "items module not loaded" end
    return I.bank(Storage.key(siteKey), itemName, n)
end

function Storage.withdraw(siteKey, itemName, n)
    local I = itemsOrNil()
    if not I then return false, "items module not loaded" end
    return I.take(Storage.key(siteKey), itemName, n)
end

function Storage.stockOf(siteKey)
    local I = itemsOrNil()
    if not I then return {}, 0 end
    return I.bagOf(Storage.key(siteKey))
end

-- ---------------------------------------------------------------------------
-- Storage.transfer -- the conservation-critical operation
-- ---------------------------------------------------------------------------
-- DEBIT FIRST, THEN CREDIT. If the debit fails nothing was created; if the
-- credit somehow fails the debit is rolled back. Crediting first would mean a
-- failed debit leaves goods in both places -- duplication that reads as a
-- generous bug rather than a broken one, and that is the version people ship.
--
-- `fromKey` and `toKey` are raw owner keys: use Storage.key(site) for a site and
-- a bare character name for a character, so this moves goods in any direction --
-- fisher to dock, dock to trader, camp to camp.
function Storage.transfer(fromKey, toKey, itemName, n)
    n = tonumber(n) or 1
    local I = itemsOrNil()
    if not I then return 0, "items module not loaded" end
    if fromKey == toKey then return 0, "same owner" end
    if n <= 0 then return 0, "nothing to move" end

    local fromBag = I.bagOf(fromKey)
    local have = fromBag[itemName] or 0
    if have <= 0 then return 0, "source holds none" end
    if n > have then n = have end          -- move what exists, report honestly

    if not I.take(fromKey, itemName, n) then
        return 0, "debit failed"
    end
    local credited = I.bank(toKey, itemName, n)
    if not credited then
        -- Roll back rather than leaving goods destroyed. A failed transfer must
        -- change nothing at all.
        I.bank(fromKey, itemName, n)
        return 0, "credit failed, rolled back"
    end
    return n, nil
end

function Storage.transferAll(fromKey, toKey)
    local I = itemsOrNil()
    if not I then return 0, "items module not loaded" end
    local bag = I.bagOf(fromKey)
    -- Snapshot the names first: mutating a table while iterating it with pairs
    -- is undefined behaviour in Lua, and this loop removes rows as it goes.
    local names = {}
    for name in pairs(bag) do names[#names + 1] = name end

    local moved = 0
    for _, name in ipairs(names) do
        local n = I.bagOf(fromKey)[name] or 0
        if n > 0 then
            local got = Storage.transfer(fromKey, toKey, name, n)
            moved = moved + got
        end
    end
    return moved
end

-- Storage.report(siteKey) -- what a site holds.
function Storage.report(siteKey)
    local stock, count = Storage.stockOf(siteKey)
    if count == 0 then log(tostring(siteKey) .. ": empty") return 0 end
    log(("%s: %d item(s)"):format(tostring(siteKey), count))
    for name, n in pairs(stock) do
        log(("    %-22s x%d"):format(name, n))
    end
    return count
end

-- ---------------------------------------------------------------------------
function Storage.selftest()
    local passed, failed = 0, 0
    local function check(name, cond, detail)
        if cond then passed = passed + 1
        else failed = failed + 1 log("  FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
    end

    local I = itemsOrNil()
    if not I then log("  SKIPPED: Items not loaded") return true end

    local FISHER, DOCK = "__fisher__", "dock:__test__"
    local dockKey = Storage.key(DOCK)
    for _, k in ipairs({ FISHER, dockKey }) do
        I.bags[k], I.counts[k], I.ledger[k] = nil, nil, nil
    end

    check("site keys are namespaced", Storage.key("Dock") ~= "Dock")

    I.bank(FISHER, "Small Fish", 10)
    I.bank(FISHER, "Book", 2)

    local moved = Storage.transfer(FISHER, dockKey, "Small Fish", 4)
    check("transfer moves the asked amount", moved == 4, moved)
    check("source debited", I.bagOf(FISHER)["Small Fish"] == 6)
    check("destination credited", I.bagOf(dockKey)["Small Fish"] == 4)

    -- Conservation across BOTH owners is the property that matters.
    local total = select(2, I.bagOf(FISHER)) + select(2, I.bagOf(dockKey))
    check("nothing created or destroyed", total == 12, total)

    local over, why = Storage.transfer(FISHER, dockKey, "Small Fish", 999)
    check("over-transfer moves only what exists", over == 6, over)
    check("...and does not error", why == nil)
    check("source now empty of that item", (I.bagOf(FISHER)["Small Fish"] or 0) == 0)

    local none, reason = Storage.transfer(FISHER, dockKey, "Nonexistent", 1)
    check("transfer of absent item moves nothing", none == 0)
    check("...and says why", reason == "source holds none")

    check("same-owner transfer refused", (Storage.transfer(FISHER, FISHER, "Book", 1)) == 0)

    local movedAll = Storage.transferAll(FISHER, dockKey)
    check("transferAll moves the remainder", movedAll == 2, movedAll)
    check("source fully drained", select(2, I.bagOf(FISHER)) == 0)
    check("destination holds everything", select(2, I.bagOf(dockKey)) == 12)
    check("invariants clean after transfers", #I.verify() == 0)

    for _, k in ipairs({ FISHER, dockKey }) do
        I.bags[k], I.counts[k], I.ledger[k] = nil, nil, nil
    end
    log(("--- SELFTEST: %d passed, %d failed ---"):format(passed, failed))
    return failed == 0
end

log("16_storage loaded -- Storage.deposit / .withdraw / .transfer / .selftest()")
