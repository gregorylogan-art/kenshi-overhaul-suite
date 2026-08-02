-- ============================================================================
-- MINT: crack createItem's 6-arg form using a `hand`
--
-- Progress so far:
--   getDataByName("Dried Fish", 4) -> GameData        VERIFIED (real vanilla fish)
--   copyItem(existingItem)         -> Item            VERIFIED
--   inv:addItem(item,1,true,false) -> true            VERIFIED
--   BUT copyItem copies the SOURCE item, so it minted a weapon, not a fish.
--
-- The remaining door is createItem. Its errors have been a reliable spec:
--   createItem(gd, 1)                  -> "expected 1 or 6 args"
--   createItem(gd)                     -> ok, returns nil (queues, no handle back)
--   createItem(gd, pos, ...)           -> "bad argument #3 (hand expected, got table)"
-- So arg#2 = GameData (accepted) and arg#3 = a `hand`.
-- Inventory:getHandle() returns a KenshiLua.hand (verified in the sweep), and an
-- owner handle is the natural second parameter for "create item FOR x".
--
-- This sweeps arg#3 candidates and then walks the remaining slots, reading each
-- error to learn the next expected type. Errors are the documentation here.
--
-- SAFETY: no engine internals (process/mainThreadUpdate are BANNED -- they
-- crashed the game). Only createItem/copyItem/addItem, all pcall-wrapped.
-- ============================================================================

local TAG = "[MINT3] "
local function log(m) print(TAG .. tostring(m)) end

local fired = false
registerHandler("onCharsUpdate", function()
    if fired then return end
    local okC, char = pcall(function() return getSelectedCharacter() end)
    if not okC or not char then return end
    fired = true

    log("========== MINT: hand-based createItem ==========")

    -- container (validated route)
    local container
    do
        local ok, c = pcall(function() return char:getFaction():getData().sourceContainer end)
        if ok then container = c end
    end
    if not container then log("no container") return end

    local okFish, fishData = pcall(function() return container:getDataByName("Dried Fish", 4) end)
    if not okFish or not fishData then log("no Dried Fish GameData") return end
    log("Dried Fish GameData: " .. tostring(fishData))

    local okInv, inv = pcall(function() return char:getInventory() end)
    if not okInv or not inv then log("no inventory") return end

    -- Collect `hand` candidates. getHandle() is the verified source.
    local hands = {}
    local function addHand(label, fn)
        local ok, h = pcall(fn)
        if ok and h ~= nil then
            hands[#hands + 1] = { label = label, h = h }
            log(("hand candidate: %-28s -> %s"):format(label, tostring(h)))
        end
    end
    addHand("inv:getHandle()",        function() return inv:getHandle() end)
    addHand("char:getHandle()",       function() return char:getHandle() end)
    addHand("weapon:getInventoryWeAreIn()", function()
        return inv:getSecondaryWeapon():getInventoryWeAreIn() end)

    if #hands == 0 then log("no hand obtainable") return end

    local factory = getRootObjectFactory()
    local okPos, pos = pcall(function() return char:getPosition() end)

    local function grant(item, how)
        local ok, res = pcall(function() return inv:addItem(item, 1, true, false) end)
        log(("  GRANT %s -> ok=%s res=%s"):format(how, tostring(ok), tostring(res)))
        if ok and res then
            log("*** REAL FISH IN INVENTORY via " .. how .. " ***")
            return true
        end
        return false
    end

    -- Walk arg shapes. Each failure names the next expected type, so even a full
    -- miss advances us.
    for _, hc in ipairs(hands) do
        local h = hc.h
        local shapes = {
            { "gd,hand,pos,nil,false,0",   function() return factory:createItem(fishData, h, pos, nil, false, 0) end },
            { "gd,hand,nil,nil,false,0",   function() return factory:createItem(fishData, h, nil, nil, false, 0) end },
            { "gd,hand,0,0,false,0",       function() return factory:createItem(fishData, h, 0, 0, false, 0) end },
            { "gd,hand,1,true,false,0",    function() return factory:createItem(fishData, h, 1, true, false, 0) end },
            { "gd,hand,false,false,false,0", function() return factory:createItem(fishData, h, false, false, false, 0) end },
        }
        for _, s in ipairs(shapes) do
            local ok, res = pcall(s[2])
            log(("[%s] createItem(%s) -> ok=%s res=%s")
                :format(hc.label, s[1], tostring(ok), tostring(res)))
            if ok and res then
                log("*** createItem RETURNED AN ITEM ***")
                if grant(res, "createItem 6-arg") then return end
            end
        end
    end

    log("no 6-arg shape produced an Item -- read the argument errors above")
    log("========== END ==========")
end)

log("mint-hand probe armed")
