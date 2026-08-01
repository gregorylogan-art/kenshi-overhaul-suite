-- ============================================================================
-- FINAL BLOCKER PROBE: find the item `category` int and a real item name.
--
-- Chain is fully mapped; only two literals are missing:
--   char:getFaction():getData()          -> GameData            VERIFIED
--     .sourceContainer                   -> GameDataContainer   <- test
--     :getDataByName(name, category)     -> GameData            <- need name+category
--   getRootObjectFactory():createItem(gameData) -> Item         <- 1 or 6 args
--   inv:addItem(item, 1, true, false)    -> true                VERIFIED
--
-- Strategy: sweep category ints against known-real vanilla Kenshi item names.
-- A hit prints the resolved GameData, which gives us both literals at once.
-- "Raw Meat" is the ideal placeholder fish -- it already exists in vanilla, so
-- v0.5 can grant a REAL item today, with the FCS fish item coming after.
--
-- SAFE: lookups + one creation attempt. Nothing is granted or mutated here.
-- ============================================================================

local TAG = "[TYPE] "
local function log(m) print(TAG .. tostring(m)) end

local NAMES = {
    "Raw Meat", "raw meat", "Foodcube", "Dried Meat", "Bread",
    "Iron Plates", "Copper", "Rice", "Ration Pack", "Fish",
}

local MAX_CATEGORY = 40

local fired = false
registerHandler("onCharsUpdate", function()
    if fired then return end
    local okC, char = pcall(function() return getSelectedCharacter() end)
    if not okC or not char then return end
    fired = true

    log("============ ITEM TYPE PROBE ============")

    -- 1. Reach a GameDataContainer via the one GameData we know works.
    local okF, fac = pcall(function() return char:getFaction() end)
    if not okF or not fac then log("no faction") return end
    local okD, gd = pcall(function() return fac:getData() end)
    if not okD or not gd then log("faction:getData() failed") return end
    log("faction GameData: " .. tostring(gd))
    for _, k in ipairs({ "name", "stringID", "type" }) do
        local ok, v = pcall(function() return gd[k] end)
        log(("   .%s = %s"):format(k, ok and tostring(v) or "ERR"))
    end

    local okS, container = pcall(function() return gd.sourceContainer end)
    if not okS or not container then
        log("gd.sourceContainer FAILED -- need another route to GameDataContainer")
        return
    end
    log("sourceContainer: " .. tostring(container))
    if not container.getDataByName then
        log("container has no getDataByName")
        return
    end

    -- 2. Sweep category ints x names. Report only hits; misses are expected.
    log("--- sweeping getDataByName(name, category) ---")
    local hits, firstHit = 0, nil
    for _, name in ipairs(NAMES) do
        for cat = 0, MAX_CATEGORY do
            local ok, res = pcall(function() return container:getDataByName(name, cat) end)
            if ok and res ~= nil then
                hits = hits + 1
                log(("HIT  name=%q category=%d -> %s"):format(name, cat, tostring(res)))
                local okN, n = pcall(function() return res.name end)
                local okI, sid = pcall(function() return res.stringID end)
                local okT, ty = pcall(function() return res.type end)
                log(("     .name=%s .stringID=%s .type=%s")
                    :format(okN and tostring(n) or "?", okI and tostring(sid) or "?",
                            okT and tostring(ty) or "?"))
                if not firstHit then firstHit = res end
                break   -- found this name's category; next name
            end
        end
    end
    log(("--- sweep done: %d hit(s) ---"):format(hits))

    -- 3. If we resolved any item type, prove createItem accepts it.
    if firstHit then
        local ok1, r1 = pcall(function() return getRootObjectFactory():createItem(firstHit) end)
        log(("createItem(gameData) -> ok=%s res=%s"):format(tostring(ok1), tostring(r1)))
        if ok1 and r1 then
            log("*** MINT CHAIN COMPLETE -- item created, ready to grant ***")
        end
    else
        log("no item type resolved -- try different names or a wider category range")
    end

    log("============ END ITEM TYPE PROBE ============")
end)

log("item-type probe armed")
