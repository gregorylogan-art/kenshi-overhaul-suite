-- ============================================================================
-- COOKING SINK -- burn chance, implemented in Lua
--
-- WHY LUA: FCS recipes have no probability/failure field (Greg checked), and
-- KenshiLua exposes no crafting callback, so the cook cannot be intercepted as
-- it happens. Instead we WATCH the inventory: when the Cooked fish count rises,
-- a cook just completed -- roll, and on a burn swap one cooked for one burnt.
--
-- CONFIRMED ITEMS (FCS, case-sensitive names!):
--   10-KenshiOverhaulSuite.mod  "Raw Fish"
--   11-KenshiOverhaulSuite.mod  "Small Fish"
--   12-KenshiOverhaulSuite.mod  "Cooked fish"   <- lowercase f
--   14-KenshiOverhaulSuite.mod  "Burnt fish"    <- lowercase f
--
-- Honest about limits: countItems / removeItemAutoDestroy signatures are
-- documented wrong like everything else here, so each is tried in several
-- shapes and the result is logged rather than assumed.
--
--   dofile("mods/KenshiLua/scripts/init/24_cooking.lua")
-- ============================================================================

local TAG = "[COOK] "
local function log(m) print(TAG .. tostring(m)) end

Cooking = Cooking or {}

Cooking.CFG = {
    burnChance   = 0.20,     -- 20% of cooks ruined
    pollTicks    = 100,      -- ~1s at the measured ~100 ticks/sec
    cookedName   = "Cooked fish",
    burntName    = "Burnt fish",
    itemCategory = 4,
}

-- reload safety (dofile would otherwise stack handlers)
if Cooking._handlers and type(unregisterHandler) == "function" then
    for _, h in ipairs(Cooking._handlers) do pcall(unregisterHandler, h) end
    log("unregistered " .. #Cooking._handlers .. " previous handler(s)")
end
Cooking._handlers = {}

local function container(char)
    local ok, c = pcall(function()
        return char:getFaction():getData().sourceContainer end)
    return ok and c or nil
end

local gdCache = {}
local function itemData(char, name)
    if gdCache[name] ~= nil then return gdCache[name] or nil end
    local c = container(char)
    if not c then return nil end
    local ok, gd = pcall(function()
        return c:getDataByName(name, Cooking.CFG.itemCategory) end)
    gdCache[name] = (ok and gd) or false
    return gdCache[name] or nil
end

-- Count how many of an item type the inventory holds. Signature unverified --
-- documented as countItems(quantity) but the runtime demanded a GameData, so
-- GameData-first is the likely real form.
local function countOf(inv, gd)
    local ok, n = pcall(function() return inv:countItems(gd) end)
    if ok and type(n) == "number" then return n end
    return nil
end

local function grantBurnt(char, inv)
    local gd = itemData(char, Cooking.CFG.burntName)
    if not gd then return false, "no Burnt fish GameData" end
    local okH, hand = pcall(function() return inv:getHandle() end)
    if not okH or not hand then return false, "no hand" end
    local item
    for _, lvl in ipairs({ 0, 1 }) do
        local ok, made = pcall(function()
            return getRootObjectFactory():createItem(gd, hand, nil, nil, lvl, nil) end)
        if ok and made then item = made break end
    end
    if not item then return false, "createItem failed" end
    local ok, res = pcall(function() return inv:addItem(item, 1, true, false) end)
    return (ok and res) and true or false, tostring(res)
end

-- Try to destroy one cooked fish. Several shapes, since the documented one is
-- almost certainly wrong.
local function removeOneCooked(inv, gd)
    local attempts = {
        { "removeItemAutoDestroy(gd,1)", function() return inv:removeItemAutoDestroy(gd, 1) end },
        { "removeItemAutoDestroy(1)",    function() return inv:removeItemAutoDestroy(1) end },
        { "getItem(gd)+autoDestroy",     function()
            local it = inv:getItem(gd)
            if it then return inv:removeItemAutoDestroy(it, 1) end
            return false end },
    }
    for _, a in ipairs(attempts) do
        local ok, res = pcall(a[2])
        if ok and res then
            log("  removed cooked via " .. a[1])
            return true
        end
    end
    return false
end

local lastCount, tick = nil, 0

Cooking._handlers[#Cooking._handlers + 1] = registerHandler("onCharsUpdate", function()
    tick = tick + 1
    if tick < Cooking.CFG.pollTicks then return end
    tick = 0

    local okC, char = pcall(function() return getSelectedCharacter() end)
    if not okC or not char then return end
    local okI, inv = pcall(function() return char:getInventory() end)
    if not okI or not inv then return end

    local gd = itemData(char, Cooking.CFG.cookedName)
    if not gd then return end

    local n = countOf(inv, gd)
    if n == nil then
        if lastCount ~= "unsupported" then
            log("countItems unsupported -- burn cannot be detected this way")
            lastCount = "unsupported"
        end
        return
    end

    if lastCount == nil or lastCount == "unsupported" then lastCount = n return end

    if n > lastCount then
        local made = n - lastCount
        log(("detected %d new Cooked fish"):format(made))
        for _ = 1, made do
            if math.random() < Cooking.CFG.burnChance then
                if removeOneCooked(inv, gd) then
                    local ok, why = grantBurnt(char, inv)
                    log("  BURNT IT -> " .. (ok and "Burnt fish granted" or ("failed: " .. tostring(why))))
                else
                    log("  burn rolled but could not remove the cooked fish")
                end
            end
        end
        n = countOf(inv, gd) or n
    end
    lastCount = n
end)

log(("cooking watcher armed -- %d%% burn chance on each Cooked fish"):format(
    Cooking.CFG.burnChance * 100))
