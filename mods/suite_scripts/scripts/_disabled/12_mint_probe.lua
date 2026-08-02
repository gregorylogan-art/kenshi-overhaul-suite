-- ============================================================================
-- TARGETED PROBE 2: minting a SPECIFIC item
--
-- Confirmed already:
--   inv:addItem(item, 1, true, false) -> true      GRANT WORKS
--   getRootObjectFactory() exposes createItem / copyItem / chooseDataFromList
--
-- Remaining unknown: how to say WHICH item. Docs claim
--   createItem(levelOverride: integer) -> Item
-- which cannot be complete -- it never names an item type. Every other call in
-- this API takes the subject first and the docs omit it (31 confirmed cases), so
-- the real shape is probably createItem(gameData, levelOverride).
--
-- GameData carries `name` and `stringID` (the FCS identifier), so identifying an
-- item type by string should be possible. This probe finds out.
--
-- SAFETY: reads + item creation only. Created items are NOT added to any
-- inventory here (we already proved granting works), so nothing is mutated.
-- ============================================================================

local TAG = "[MINT] "
local function log(m) print(TAG .. tostring(m)) end

local function describeGameData(gd, label)
    if gd == nil then log(label .. ": nil") return end
    log(label .. ": " .. tostring(gd))
    for _, k in ipairs({ "name", "stringID", "type", "id", "validity" }) do
        local ok, v = pcall(function() return gd[k] end)
        log(("   .%s = %s"):format(k, ok and tostring(v) or "ERR"))
    end
end

local fired = false
registerHandler("onCharsUpdate", function()
    if fired then return end
    local okC, char = pcall(function() return getSelectedCharacter() end)
    if not okC or not char then return end
    fired = true

    log("============== MINT PROBE ==============")

    local okF, factory = pcall(function() return getRootObjectFactory() end)
    if not okF or not factory then log("no factory") return end

    -- 1. What does an EXISTING item's GameData look like? This teaches us how
    --    item types are identified, using an item we know is valid.
    local okI, inv = pcall(function() return char:getInventory() end)
    if okI and inv then
        local okW, weapon = pcall(function() return inv:getSecondaryWeapon() end)
        if okW and weapon then
            local okD, gd = pcall(function() return weapon:getData() end)
            describeGameData(okD and gd or nil, "existing item :getData()")

            -- If that GameData is what createItem wants, this proves the shape.
            local ok1, r1 = pcall(function() return factory:createItem(gd, 1) end)
            log(("createItem(gameData, 1) -> ok=%s res=%s"):format(tostring(ok1), tostring(r1)))

            local ok2, r2 = pcall(function() return factory:createItem(gd) end)
            log(("createItem(gameData) -> ok=%s res=%s"):format(tostring(ok2), tostring(r2)))
        end
    end

    -- 2. Bare createItem -- the documented form. Expect an argument error that
    --    names the real expected type (that is how addItem was solved).
    local ok3, r3 = pcall(function() return factory:createItem(1) end)
    log(("createItem(1) -> ok=%s res=%s"):format(tostring(ok3), tostring(r3)))

    -- 3. chooseDataFromList: returns GameData from a named list. Discover which
    --    list names are real. Errors are informative, not failures.
    for _, listName in ipairs({ "items", "item", "food", "weapons", "inventory", "ITEM" }) do
        local ok, res = pcall(function() return factory:chooseDataFromList(listName, 0, 0) end)
        log(("chooseDataFromList(%q,0,0) -> ok=%s res=%s"):format(listName, tostring(ok), tostring(res)))
        if ok and res then describeGameData(res, "   list " .. listName) end
    end

    -- 4. GameData owns getGameDataReferenceObject(list, id) -- a by-name lookup.
    --    If we can reach it from an item's GameData, we can name FCS items.
    local okI2, inv2 = pcall(function() return char:getInventory() end)
    if okI2 and inv2 then
        local okW2, w2 = pcall(function() return inv2:getSecondaryWeapon() end)
        if okW2 and w2 then
            local okD2, gd2 = pcall(function() return w2:getData() end)
            if okD2 and gd2 and gd2.getGameDataReferenceObject then
                local ok4, r4 = pcall(function()
                    return gd2:getGameDataReferenceObject("items", "raw fish")
                end)
                log(("getGameDataReferenceObject('items','raw fish') -> ok=%s res=%s")
                    :format(tostring(ok4), tostring(r4)))
            else
                log("getGameDataReferenceObject not present on that GameData")
            end
        end
    end

    log("============== END MINT PROBE ==============")
end)

log("mint probe armed")
