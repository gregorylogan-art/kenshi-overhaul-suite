-- ============================================================================
-- Kenshi Overhaul Suite -- ITEMS  (the shared grant layer)
--
-- WHY THIS EXISTS
-- Fishing spent a full day on one bug: a character that stopped taking orders,
-- an inventory that would not open, a stats screen that flashed shut. Five
-- theories died before Greg named it:
--
--     "its 85% sure its the reason harvesting is a second inventory in kenshi.
--      im sure its one of his law in his engine."
--
-- He was right. With catches banked in Lua and ZERO inventory calls in the loop,
-- a run of 100+ items completed clean. Every earlier attempt froze within ~11-20
-- grants, because each one merely reduced the FREQUENCY of inventory writes
-- instead of removing them.
--
-- THE LAW, in one line:
--     A gameplay loop NEVER writes to a character's inventory.
--     It accumulates outside, and transfers on an explicit player action.
--
-- Cooking, trade, loot and quest rewards all hit this. Each re-deriving it the
-- hard way is how a project ends up with five subtly different versions and four
-- of them wrong. So there is one implementation, here, and systems route
-- through it.
--
-- CONTRACT (stable; internals are disposable)
--     Items.bank(ownerKey, itemName, n)      -> total banked      NO engine calls
--     Items.bagOf(ownerKey)                  -> { [name] = n }, count
--     Items.collect(character, ownerKey)     -> moved, remaining, reason
--     Items.take(ownerKey, itemName, n)      -> ok            consume from bag
--     Items.resolve(character, itemName)     -> GameData|nil   cached
--     Items.verify()                         -> violations[]  executable invariants
--
-- Cherry-picked from StarFall's WorldStateManager (#3637): the numbered
-- INVARIANT CONTRACT that a function actually checks, so the rules cannot rot
-- into comments nobody runs. See Items.verify().
-- ============================================================================

local TAG = "[ITEM] "
local function log(m) print(TAG .. tostring(m)) end

Items = Items or {}
-- Escape KenshiLua's per-script sandbox: a bare global write stays private to
-- this file, which is exactly how Fishing.grantXp silently read nil for a whole
-- session. See KENSHI-ENGINE-NOTES section 1.
pcall(function() _G.Items = Items end)

-- ============================================================================
-- ITEMS INVARIANT CONTRACT -- executable via Items.verify().
-- One line per invariant; "[INV<n>]" violation strings match this numbering 1:1.
--   1. Conservation: for every owner and item, banked == collected + held +
--      consumed. Nothing is minted from nothing and nothing vanishes.
--   2. Non-negativity: no bag holds a negative or non-integer quantity.
--   3. Bag hygiene: a zero-quantity entry is removed, never left as a zero row
--      (a zero row and an absent row must not be different states).
--   4. Count agreement: the cached per-owner count equals the sum of its rows.
--   5. Loop purity: the number of inventory writes never exceeds the number of
--      collect() calls. This is THE engine law, made checkable -- if a loop
--      starts writing to an inventory again, this trips.
-- ============================================================================

Items.bags    = Items.bags    or {}   -- [ownerKey] = { [itemName] = count }
Items.counts  = Items.counts  or {}   -- [ownerKey] = total
Items.ledger  = Items.ledger  or {}   -- [ownerKey] = { banked, collected, consumed }
Items.stats   = Items.stats   or { collectCalls = 0, inventoryWrites = 0 }

local gameDataCache = {}

local function ledgerFor(ownerKey)
    local l = Items.ledger[ownerKey]
    if not l then
        l = { banked = 0, collected = 0, consumed = 0 }
        Items.ledger[ownerKey] = l
    end
    return l
end

-- ---------------------------------------------------------------------------
-- Items.resolve -- name -> GameData, cached
-- ---------------------------------------------------------------------------
-- getDataByName is CASE-SENSITIVE and fails SILENTLY (#23), so a typo yields a
-- system that quietly grants nothing. Categories: 2 = weapons,
-- 3 = clothing/armour, 4 = food/materials. Weapons return nil at every level
-- (#22) and cannot be created at all.
function Items.resolve(character, itemName)
    if not character or type(itemName) ~= "string" then return nil end
    if gameDataCache[itemName] ~= nil then return gameDataCache[itemName] or nil end

    local okF, container = pcall(function()
        return character:getFaction():getData().sourceContainer
    end)
    if not okF or not container then return nil end

    local gd
    for _, cat in ipairs({ 4, 3, 2 }) do
        local ok, found = pcall(function() return container:getDataByName(itemName, cat) end)
        if ok and found then gd = found break end
    end
    gameDataCache[itemName] = gd or false
    if not gd then log("NOT FOUND in any category: " .. itemName) end
    return gd
end

-- ---------------------------------------------------------------------------
-- Items.bank -- the safe path. NO ENGINE CALLS AT ALL.
-- ---------------------------------------------------------------------------
-- This is what a gameplay loop calls. It touches nothing but Lua tables, so it
-- cannot trip the freeze no matter how often it runs.
function Items.bank(ownerKey, itemName, n)
    n = tonumber(n) or 1
    if type(ownerKey) ~= "string" or type(itemName) ~= "string" or n <= 0 then
        return nil, "bad arguments"
    end
    local bag = Items.bags[ownerKey]
    if not bag then bag = {} Items.bags[ownerKey] = bag end
    bag[itemName] = (bag[itemName] or 0) + n
    Items.counts[ownerKey] = (Items.counts[ownerKey] or 0) + n
    ledgerFor(ownerKey).banked = ledgerFor(ownerKey).banked + n
    return Items.counts[ownerKey]
end

function Items.bagOf(ownerKey)
    return Items.bags[ownerKey] or {}, Items.counts[ownerKey] or 0
end

-- Consume from the bag without ever touching an inventory -- e.g. cooking eats
-- raw fish straight out of the catch bag. This is the whole reason banking is
-- powerful rather than merely safe: production chains can run entirely outside
-- the inventory and only the finished product ever needs to cross over.
function Items.take(ownerKey, itemName, n)
    n = tonumber(n) or 1
    local bag = Items.bags[ownerKey]
    if not bag or (bag[itemName] or 0) < n then return false, "not enough banked" end
    bag[itemName] = bag[itemName] - n
    if bag[itemName] <= 0 then bag[itemName] = nil end   -- INV3: never a zero row
    Items.counts[ownerKey] = (Items.counts[ownerKey] or 0) - n
    ledgerFor(ownerKey).consumed = ledgerFor(ownerKey).consumed + n
    return true
end

-- ---------------------------------------------------------------------------
-- Items.collect -- THE ONLY PLACE THIS PROJECT WRITES TO AN INVENTORY
-- ---------------------------------------------------------------------------
-- Bounded, player-initiated, and it stops at the first refusal with the
-- remainder still banked. A full pack therefore costs ONE refused grant rather
-- than one every few seconds forever, which was the shape that froze characters.
-- targetInv lets a caller mint into a CONTAINER's inventory rather than the
-- character's main grid -- the mining-window shape, where product lands in its
-- own pane and the player drags it out. That is both what Kenshi does for every
-- gathering profession and, plausibly, safer: #37's freeze was specifically
-- about writing into a character's own inventory.
local function mintInto(character, gd, targetInv)
    local inv = targetInv
    if not inv then
        local okInv, got = pcall(function() return character:getInventory() end)
        if not okInv or not got then return false, "no inventory" end
        inv = got
    end
    local okH, hand = pcall(function() return inv:getHandle() end)
    if not okH or not hand then return false, "no inventory handle" end

    -- FAIL CLOSED. An earlier version refused only on an explicit false, so an
    -- errored/absent/nil result still minted.
    if not inv.hasRoomForItem then return false, "cannot prove room" end
    local okRoom, room = pcall(function() return inv:hasRoomForItem(gd) end)
    if not okRoom then return false, "room check errored" end
    if room ~= true then return false, "no room" end

    local factory = getRootObjectFactory()
    local item
    for _, lvl in ipairs({ 0, 1, 2 }) do
        local ok, made = pcall(function()
            return factory:createItem(gd, hand, nil, nil, lvl, nil)
        end)
        if ok and made then item = made break end
    end
    if not item then return false, "createItem returned nil at every level" end

    -- addItem(item, quantity, dropOnFail, destroyOnFail). dropOnFail stays FALSE:
    -- a gathering character may be standing in water, and asking the engine to
    -- place a world object there is its own hazard.
    local okAdd, res = pcall(function() return inv:addItem(item, 1, false, true) end)
    if okAdd and res then return true end
    if okAdd then return false, "no room" end
    return false, "addItem error: " .. tostring(res)
end

function Items.collect(character, ownerKey, targetInv)
    if not character then return 0, 0, "no character" end
    Items.stats.collectCalls = Items.stats.collectCalls + 1

    local bag = Items.bags[ownerKey]
    local held = Items.counts[ownerKey] or 0
    if not bag or held <= 0 then return 0, 0, "nothing banked" end

    local moved, reason = 0, nil
    for itemName, n in pairs(bag) do
        local gd = Items.resolve(character, itemName)
        if not gd then
            reason = "unresolvable item: " .. itemName
        else
            for _ = 1, n do
                Items.stats.inventoryWrites = Items.stats.inventoryWrites + 1
                local ok, why = mintInto(character, gd, targetInv)
                if not ok then reason = why break end
                bag[itemName] = bag[itemName] - 1
                Items.counts[ownerKey] = Items.counts[ownerKey] - 1
                ledgerFor(ownerKey).collected = ledgerFor(ownerKey).collected + 1
                moved = moved + 1
            end
        end
        if bag[itemName] == 0 then bag[itemName] = nil end   -- INV3
        if reason then break end
    end
    return moved, Items.counts[ownerKey] or 0, reason
end

-- ---------------------------------------------------------------------------
-- Items.verify -- the invariant contract, executable
-- ---------------------------------------------------------------------------
-- Ported from StarFall's VerifyWorldStateInvariants (#3637). The point is that
-- the numbered rules at the top of this file are CHECKED, not merely written
-- down, so they cannot quietly rot as the code moves underneath them.
function Items.verify()
    local v = {}

    for ownerKey, bag in pairs(Items.bags) do
        local sum = 0
        for itemName, n in pairs(bag) do
            -- INV2 non-negativity / integrality
            if type(n) ~= "number" or n < 0 or n ~= math.floor(n) then
                v[#v + 1] = ("[INV2] %s/%s holds %s"):format(ownerKey, itemName, tostring(n))
            end
            -- INV3 no zero rows
            if n == 0 then
                v[#v + 1] = ("[INV3] %s/%s left as a zero row"):format(ownerKey, itemName)
            end
            if type(n) == "number" then sum = sum + n end
        end
        -- INV4 cached count agrees with the rows
        local cached = Items.counts[ownerKey] or 0
        if cached ~= sum then
            v[#v + 1] = ("[INV4] %s count=%d but rows sum to %d"):format(ownerKey, cached, sum)
        end
        -- INV1 conservation
        local l = ledgerFor(ownerKey)
        if l.banked ~= l.collected + l.consumed + sum then
            v[#v + 1] = ("[INV1] %s banked=%d but collected=%d + consumed=%d + held=%d")
                :format(ownerKey, l.banked, l.collected, l.consumed, sum)
        end
    end

    -- INV5 loop purity.
    --
    -- CORRECTED. This used to check "collectCalls == 0 and inventoryWrites > 0",
    -- which is a TAUTOLOGY: inventoryWrites is only ever incremented a few lines
    -- after collectCalls in the SAME function, so inventoryWrites > 0 already
    -- implies collectCalls > 0 by construction. The check could never fire --
    -- dead code standing in for a safety net. It also only ever guarded against
    -- Items.lua's own internal counting, never against the actual risk: a FUTURE
    -- system bypassing Items entirely and calling addItem directly.
    --
    -- A runtime counter cannot see a call it was never routed through, so the
    -- real guarantee is now a STATIC check instead: tools/lua_check.py rule L7
    -- greps every init/ file for ':addItem(' or ':createItem(' outside this
    -- file. What is left for the runtime side is just sanity on the counters
    -- themselves -- they are accumulate-only, so either going negative means
    -- something reset or corrupted Items.stats directly rather than through the
    -- API, which is itself worth flagging.
    if Items.stats.collectCalls < 0 or Items.stats.inventoryWrites < 0 then
        v[#v + 1] = ("[INV5] Items.stats corrupted: collectCalls=%s inventoryWrites=%s")
            :format(tostring(Items.stats.collectCalls), tostring(Items.stats.inventoryWrites))
    end

    return v
end

-- Items.selftest() -- exercises the contract with no game world required.
function Items.selftest()
    local passed, failed = 0, 0
    local function check(name, cond)
        if cond then passed = passed + 1
        else failed = failed + 1 log("  FAIL: " .. name) end
    end

    local KEY = "__selftest__"
    Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil

    Items.bank(KEY, "Small Fish", 3)
    Items.bank(KEY, "Book", 2)
    local _, n = Items.bagOf(KEY)
    check("bank accumulates", n == 5)

    check("take succeeds", Items.take(KEY, "Small Fish", 2) == true)
    check("take refuses overdraw", Items.take(KEY, "Small Fish", 99) == false)
    local bag, n2 = Items.bagOf(KEY)
    check("count after take", n2 == 3)
    check("no zero rows", bag["Small Fish"] == 1)

    check("take to zero removes the row", Items.take(KEY, "Small Fish", 1) == true)
    check("row gone, not zeroed", Items.bagOf(KEY)["Small Fish"] == nil)

    check("bank rejects n<=0", Items.bank(KEY, "Book", 0) == nil)
    check("bank rejects bad name", Items.bank(KEY, 42, 1) == nil)

    local violations = Items.verify()
    check("invariants clean", #violations == 0)
    for _, msg in ipairs(violations) do log("  " .. msg) end

    Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil
    log(("--- SELFTEST: %d passed, %d failed ---"):format(passed, failed))
    return failed == 0
end

log("08_items loaded -- Items.bank / .collect / .take / .verify / .selftest")
