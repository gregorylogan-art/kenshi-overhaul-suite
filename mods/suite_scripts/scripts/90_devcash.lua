-- ============================================================================
-- DEV: give the player money (cats)
--
-- Testing a fishing/cooking economy needs a solvent player. Dying broke in a
-- start town is a test-harness problem, not a design signal.
--
-- MANUAL ONLY. This lives outside scripts/init/, so it never auto-loads and
-- cannot fire during normal play. Load it when you want it:
--     dofile("mods/KenshiLua/scripts/90_devcash.lua")
--     DevCash.give(10000)
--
-- The money route is NOT documented as a single call, so this tries several in
-- order and REPORTS WHICH ONE WORKED. It also reads the balance before and
-- after and only claims success if the number actually moved -- this project
-- has already had one "SUCCESS" log for an item that was never in the
-- inventory, caught only because Greg looked at his actual screen.
--
-- Safety: every call is pcall-wrapped, no container types are touched (those
-- hard-crash the game twice over), and no engine internals like process() or
-- mainThreadUpdate() are called.
-- ============================================================================

local TAG = "[CASH] "
local function log(m) print(TAG .. tostring(m)) end

DevCash = DevCash or {}

-- Read the balance through whichever getter answers. Returns number or nil.
local function readBalance(character)
    local ok, v = pcall(function() return character:getMoney() end)
    if ok and type(v) == "number" then return v, "character:getMoney()" end

    local okI, inv = pcall(function() return character:getInventory() end)
    if okI and inv then
        local ok2, v2 = pcall(function() return inv:getMoney() end)
        if ok2 and type(v2) == "number" then return v2, "inventory:getMoney()" end
    end
    return nil, "no readable balance"
end

-- Each entry: a label and a function that attempts the credit.
-- Ordered most-likely-correct first; the first one that MOVES the balance wins.
local ROUTES = {
    { "character:getOwnerships():addMoney", function(c, n)
        local o = c:getOwnerships()
        o:addMoney(n)
    end },
    { "faction:getOwnerships():addMoney", function(c, n)
        local o = c:getFaction():getOwnerships()
        o:addMoney(n)
    end },
    { "character:addMoney", function(c, n) c:addMoney(n) end },
    -- takeMoney with a NEGATIVE amount. Last resort: a clamped or unsigned
    -- implementation could take money instead of giving it, so this only runs
    -- if everything above failed, and the balance check below catches it.
    { "character:takeMoney(-n)", function(c, n) c:takeMoney(-n) end },
}

-- DevCash.give(10000) -- credit the selected character.
function DevCash.give(amount)
    amount = tonumber(amount) or 10000

    local ok, character = pcall(function() return getSelectedCharacter() end)
    if not ok or not character then
        log("select a character first (click one), then run DevCash.give(10000)")
        return false
    end

    local before, how = readBalance(character)
    log(("balance before: %s  (%s)"):format(tostring(before), how))

    for _, route in ipairs(ROUTES) do
        local label, fn = route[1], route[2]
        local okCall, err = pcall(fn, character, amount)
        if not okCall then
            log(("  %-38s -> error: %s"):format(label, tostring(err)))
        else
            local after = readBalance(character)
            -- PROVE it moved. A call that returns cleanly but changes nothing is
            -- the exact failure mode that produced a false SUCCESS before.
            if type(before) == "number" and type(after) == "number" then
                if after > before then
                    log(("  %-38s -> OK  %d -> %d"):format(label, before, after))
                    log(("GAVE %d cats via %s"):format(after - before, label))
                    return true
                end
                log(("  %-38s -> no change (%d)"):format(label, after))
            else
                -- Balance unreadable: report honestly rather than claiming a win.
                log(("  %-38s -> called, but balance is unreadable"):format(label))
            end
        end
    end

    log("no route credited money. Check the cats counter -- if it moved, the")
    log("balance getter is wrong rather than the credit; tell me the number.")
    return false
end

-- DevCash.check() -- just read the balance, change nothing.
function DevCash.check()
    local ok, character = pcall(function() return getSelectedCharacter() end)
    if not ok or not character then log("select a character first") return end
    local bal, how = readBalance(character)
    log(("balance: %s  (%s)"):format(tostring(bal), how))
    return bal
end

log("loaded. DevCash.give(10000)  |  DevCash.check()")
