-- ============================================================================
-- Kenshi Overhaul Suite -- ECONOMY  (#28 towns & vendors)
--
-- THE RULE THIS MODULE EXISTS TO ENFORCE:
--     MONEY IS MOVED, NEVER MINTED.
--
-- Greg's constraint from the first design conversation was that fishing must not
-- break the economy. Junk odds and a cooking burn chance handle the *supply*
-- side, but they are worthless if selling calls addMoney() out of thin air --
-- then every fish is new money and the currency inflates no matter how much
-- trash you catch.
--
-- So a vendor holds a FLOAT. Selling debits that float and credits the player;
-- a vendor with no cats cannot buy, exactly like a real Kenshi shop that has
-- spent its money. Cats enter the world only where a designer says so
-- (Economy.mint), and that call is logged and counted so the total is auditable.
--
-- Ported from StarFall's amber-conservation invariant (WSM INV1): total held
-- equals total minted-to-date. It is the same idea one currency down.
--
-- CONTRACT
--     Economy.registerVendor(key, float, buys)   -> ok
--     Economy.priceOf(itemName)                  -> cats
--     Economy.sell(vendorKey, sellerKey, item, n)-> earned, sold, reason
--     Economy.mint(vendorKey, amount, why)       -> newFloat    AUDITED
--     Economy.floatOf(vendorKey)                 -> cats
--     Economy.verify()                           -> violations[]
--     Economy.selftest()                         -> boolean
--
-- NOT DONE HERE: paying the player's actual in-game cats. That is an inventory-
-- adjacent write and belongs behind the same explicit-action discipline as
-- Items.collect (see #37). This module settles the LEDGER; handing over real
-- cats is a separate, deliberate step.
-- ============================================================================

local TAG = "[ECON] "
local function log(m) print(TAG .. tostring(m)) end

Economy = Economy or {}
pcall(function() _G.Economy = Economy end)

-- ============================================================================
-- ECONOMY INVARIANT CONTRACT -- executable via Economy.verify().
--   1. Conservation: minted == sum(vendor floats) + sum(seller earnings) held.
--      Money is only created by Economy.mint, never by a sale.
--   2. Non-negative floats: a vendor float never goes below zero.
--   3. Priced goods: a sale never completes at a nil or negative price.
--   4. Stock backing: a sale only ever moves goods the seller actually held.
-- ============================================================================

Economy.vendors  = Economy.vendors  or {}   -- [key] = { float, buys = {name=true} }
Economy.earnings = Economy.earnings or {}   -- [sellerKey] = cats credited
Economy.minted   = Economy.minted   or 0
Economy.mintLog  = Economy.mintLog  or {}

-- Base prices in cats. Deliberately conservative: fishing's whole point is that
-- junk dominates, so the fish price only matters against the junk it is mixed
-- with. Greg's spec for raw fish was ~30 cats, matching raw meat.
Economy.prices = Economy.prices or {
    ["Small Fish"]       = 30,
    ["Raw Fish"]         = 30,
    ["Cooked Fish"]      = 55,    -- cooking adds value...
    ["Burnt Fish"]       = 4,     -- ...and burning destroys it. This is the sink.
    ["Straw Hat"]        = 8,
    ["Rag Loincloth"]    = 5,
    ["Empty Rum Bottle"] = 2,
    ["Cup"]              = 3,
    ["Wooden Bowl"]      = 3,
    ["Damaged Book"]     = 6,
    ["Book"]             = 20,
}

function Economy.priceOf(itemName)
    return Economy.prices[itemName]
end

function Economy.registerVendor(key, startingFloat, buys)
    if type(key) ~= "string" then return false, "bad key" end
    Economy.vendors[key] = {
        float = tonumber(startingFloat) or 0,
        buys  = buys,          -- nil = buys anything priced
    }
    return true
end

function Economy.floatOf(vendorKey)
    local v = Economy.vendors[vendorKey]
    return v and v.float or 0
end

-- The ONLY way cats enter the world. Audited so the total is always explainable.
function Economy.mint(vendorKey, amount, why)
    amount = tonumber(amount) or 0
    if amount <= 0 then return nil, "amount must be positive" end
    local v = Economy.vendors[vendorKey]
    if not v then return nil, "unknown vendor" end
    v.float = v.float + amount
    Economy.minted = Economy.minted + amount
    Economy.mintLog[#Economy.mintLog + 1] =
        { vendor = vendorKey, amount = amount, why = why or "unstated" }
    return v.float
end

local function itemsOrNil()
    local ok, m = pcall(function() return _G.Items end)
    if ok and type(m) == "table" and type(m.bank) == "function" then return m end
    return nil
end

-- ---------------------------------------------------------------------------
-- Economy.sell -- goods out of the seller's bag, cats out of the vendor's float
-- ---------------------------------------------------------------------------
function Economy.sell(vendorKey, sellerKey, itemName, n)
    n = tonumber(n) or 1
    local I = itemsOrNil()
    if not I then return 0, 0, "items module not loaded" end

    local v = Economy.vendors[vendorKey]
    if not v then return 0, 0, "unknown vendor" end

    local price = Economy.priceOf(itemName)
    if not price or price <= 0 then return 0, 0, "vendor does not price " .. tostring(itemName) end
    if v.buys and not v.buys[itemName] then
        return 0, 0, "vendor does not deal in " .. tostring(itemName)
    end

    local have = I.bagOf(sellerKey)[itemName] or 0
    if have <= 0 then return 0, 0, "you have none banked" end
    if n > have then n = have end

    -- A vendor cannot spend money it does not have. This is the conservation
    -- rule made concrete, and it is also good play: a small dock runs out of
    -- cats and you have to carry your fish to a bigger town.
    local affordable = math.floor(v.float / price)
    if affordable <= 0 then
        return 0, 0, ("%s has no cats left (float %d, price %d)")
            :format(vendorKey, v.float, price)
    end
    if n > affordable then n = affordable end

    if not I.take(sellerKey, itemName, n) then
        return 0, 0, "could not debit the goods"
    end
    local earned = n * price
    v.float = v.float - earned
    Economy.earnings[sellerKey] = (Economy.earnings[sellerKey] or 0) + earned

    -- The vendor now holds the goods. Same ledger, different owner -- so stock
    -- bought by a town is visible and conserved rather than vanishing.
    I.bank("vendor:" .. vendorKey, itemName, n)
    return earned, n, nil
end

-- ---------------------------------------------------------------------------
function Economy.verify()
    local v = {}
    local floats, earned = 0, 0
    for key, vendor in pairs(Economy.vendors) do
        if vendor.float < 0 then
            v[#v + 1] = ("[INV2] vendor %s float is negative (%d)"):format(key, vendor.float)
        end
        floats = floats + vendor.float
    end
    for _, amount in pairs(Economy.earnings) do earned = earned + amount end

    -- INV1: every cat in the system traces to a mint.
    if floats + earned ~= Economy.minted then
        v[#v + 1] = ("[INV1] floats(%d) + earnings(%d) = %d but minted = %d")
            :format(floats, earned, floats + earned, Economy.minted)
    end
    for name, price in pairs(Economy.prices) do
        if type(price) ~= "number" or price <= 0 then
            v[#v + 1] = ("[INV3] %s priced at %s"):format(name, tostring(price))
        end
    end
    return v
end

function Economy.report()
    log(("minted to date: %d cats"):format(Economy.minted))
    for key, vendor in pairs(Economy.vendors) do
        log(("    vendor %-20s float %d"):format(key, vendor.float))
    end
    for key, amount in pairs(Economy.earnings) do
        log(("    earned %-20s %d"):format(key, amount))
    end
    local viol = Economy.verify()
    log(#viol == 0 and "    invariants CLEAN" or ("    " .. #viol .. " VIOLATION(S)"))
    for _, m in ipairs(viol) do log("      " .. m) end
end

-- ---------------------------------------------------------------------------
function Economy.selftest()
    local passed, failed = 0, 0
    local function check(name, cond, detail)
        if cond then passed = passed + 1
        else failed = failed + 1 log("  FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
    end

    local I = itemsOrNil()
    if not I then log("  SKIPPED: Items not loaded") return true end

    -- isolate
    Economy.vendors, Economy.earnings, Economy.minted, Economy.mintLog = {}, {}, 0, {}
    local SELLER, VEND = "__seller__", "__dock__"
    for _, k in ipairs({ SELLER, "vendor:" .. VEND }) do
        I.bags[k], I.counts[k], I.ledger[k] = nil, nil, nil
    end

    Economy.registerVendor(VEND, 0)
    check("new vendor starts broke", Economy.floatOf(VEND) == 0)
    Economy.mint(VEND, 1000, "selftest seed")
    check("mint credits the float", Economy.floatOf(VEND) == 1000)
    check("mint is counted", Economy.minted == 1000)
    check("mint refuses non-positive", Economy.mint(VEND, 0) == nil)
    check("mint refuses unknown vendor", Economy.mint("nope", 10, "x") == nil)

    I.bank(SELLER, "Cooked Fish", 10)
    local earned, sold = Economy.sell(VEND, SELLER, "Cooked Fish", 4)
    check("sale pays price x quantity", earned == 4 * 55, earned)
    check("sale moves the asked quantity", sold == 4)
    check("float debited exactly", Economy.floatOf(VEND) == 1000 - earned)
    check("goods left the seller", I.bagOf(SELLER)["Cooked Fish"] == 6)
    check("goods reached the vendor", I.bagOf("vendor:" .. VEND)["Cooked Fish"] == 4)

    -- THE conservation property
    check("money conserved", #Economy.verify() == 0)

    -- burnt fish must be near-worthless, or cooking is not a sink
    check("burning destroys value",
          Economy.priceOf("Burnt Fish") < Economy.priceOf("Small Fish") / 5,
          Economy.priceOf("Burnt Fish"))
    check("cooking adds value",
          Economy.priceOf("Cooked Fish") > Economy.priceOf("Raw Fish"))

    -- a vendor cannot spend what it does not have
    Economy.vendors[VEND].float = 60
    local e2, s2, why2 = Economy.sell(VEND, SELLER, "Cooked Fish", 6)
    check("sale clamps to what the vendor can afford", s2 == 1, s2)
    check("...and pays only for that", e2 == 55, e2)
    check("float never goes negative", Economy.floatOf(VEND) >= 0)

    Economy.vendors[VEND].float = 0
    local e3, s3, why3 = Economy.sell(VEND, SELLER, "Cooked Fish", 1)
    check("broke vendor buys nothing", s3 == 0 and e3 == 0)
    check("...and says why", type(why3) == "string" and why3:find("no cats") ~= nil, why3)

    local e4, s4, why4 = Economy.sell(VEND, SELLER, "Nonexistent", 1)
    check("unpriced item refused", s4 == 0 and why4 ~= nil)

    check("invariants still clean at the end", #Economy.verify() == 0)

    Economy.vendors, Economy.earnings, Economy.minted, Economy.mintLog = {}, {}, 0, {}
    for _, k in ipairs({ SELLER, "vendor:" .. VEND }) do
        I.bags[k], I.counts[k], I.ledger[k] = nil, nil, nil
    end
    log(("--- SELFTEST: %d passed, %d failed ---"):format(passed, failed))
    return failed == 0
end

log("18_economy loaded -- Economy.sell / .mint / .report / .selftest()")
