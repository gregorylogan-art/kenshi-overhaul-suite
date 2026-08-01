-- ============================================================================
-- MINT: final strategies + fish-item discovery
--
-- KNOWN GOOD:
--   container:getDataByName(name, 4) -> GameData        (category 4 = items)
--   inv:addItem(item, 1, true, false) -> true
--
-- OPEN: createItem(gameData) returns ok=true res=NIL. The factory owns
--   todoList / mainThreadUpdate() / process(), so creation is probably QUEUED,
--   and the docs' "1 or 6 args" implies a 6-arg immediate form mirroring
--   create(position, isFromActiveLevelMod, rotation, invisible, age).
--
-- Four strategies, cheapest first. First one that yields an Item wins.
-- Also sweeps fish-flavoured names -- Greg reports vanilla Kenshi already ships
-- fish and cooked-fish icons, so a real fish item may already exist.
-- ============================================================================

local TAG = "[MINT2] "
local function log(m) print(TAG .. tostring(m)) end

local FISH_NAMES = {
    "Fish", "Raw Fish", "Cooked Fish", "Dried Fish", "Fish Meat",
    "Grilled Fish", "Salted Fish", "Riverfish", "Cave Fish", "Fishmeat",
    "Smoked Fish", "Fresh Fish",
}

local fired = false
registerHandler("onCharsUpdate", function()
    if fired then return end
    local okC, char = pcall(function() return getSelectedCharacter() end)
    if not okC or not char then return end
    fired = true

    log("============ MINT FINAL ============")

    local container
    do
        local ok1, fac = pcall(function() return char:getFaction() end)
        local ok2, gd = ok1 and pcall(function() return fac:getData() end)
        if ok2 and gd then
            local ok3, c = pcall(function() return gd.sourceContainer end)
            if ok3 then container = c end
        end
    end
    if not container then log("no GameDataContainer") return end

    -- ---- FISH HUNT: does vanilla already have a fish item? ----
    log("--- fish item search (category 4) ---")
    local fishData
    for _, n in ipairs(FISH_NAMES) do
        local ok, res = pcall(function() return container:getDataByName(n, 4) end)
        if ok and res ~= nil then
            local okS, sid = pcall(function() return res.stringID end)
            log(("FISH HIT %q -> stringID=%s"):format(n, okS and tostring(sid) or "?"))
            fishData = fishData or res
        end
    end
    if not fishData then log("no fish item in vanilla -- FCS will define one") end

    -- Fall back to Raw Meat as the placeholder so we can still prove the mint.
    local itemData = fishData
    if not itemData then
        local ok, res = pcall(function() return container:getDataByName("Raw Meat", 4) end)
        if ok then itemData = res end
        log("using Raw Meat as placeholder: " .. tostring(itemData))
    end
    if not itemData then log("no item GameData at all") return end

    local factory = getRootObjectFactory()
    local okInv, inv = pcall(function() return char:getInventory() end)
    if not okInv or not inv then log("no inventory") return end

    local function grant(item, how)
        if item == nil then return false end
        local ok, res = pcall(function() return inv:addItem(item, 1, true, false) end)
        log(("GRANT via %s -> ok=%s res=%s"):format(how, tostring(ok), tostring(res)))
        if ok and res then log("*** SUCCESS: item is in the inventory (" .. how .. ") ***") end
        return ok and res
    end

    -- ---- STRATEGY 1: queue then process() ----
    local ok1 = pcall(function() return factory:createItem(itemData) end)
    log("strategy1 createItem(gd) queued ok=" .. tostring(ok1))
    local okP, produced = pcall(function() return factory:process() end)
    log(("strategy1 process() -> ok=%s res=%s"):format(tostring(okP), tostring(produced)))
    if okP and produced and grant(produced, "process()") then log("DONE") return end

    -- ---- STRATEGY 2: mainThreadUpdate then process() ----
    pcall(function() factory:mainThreadUpdate() end)
    local okP2, produced2 = pcall(function() return factory:process() end)
    log(("strategy2 mainThreadUpdate+process -> ok=%s res=%s"):format(tostring(okP2), tostring(produced2)))
    if okP2 and produced2 and grant(produced2, "mainThreadUpdate+process") then log("DONE") return end

    -- ---- STRATEGY 3: 6-arg immediate form ----
    local okPos, pos = pcall(function() return char:getPosition() end)
    log("character position: " .. tostring(okPos and pos or "unavailable"))
    if okPos and pos then
        local variants = {
            { "gd,pos,false,nil,false,0", function() return factory:createItem(itemData, pos, false, nil, false, 0) end },
            { "gd,pos,true,nil,false,0",  function() return factory:createItem(itemData, pos, true, nil, false, 0) end },
            { "gd,pos,false,nil,true,0",  function() return factory:createItem(itemData, pos, false, nil, true, 0) end },
        }
        for _, v in ipairs(variants) do
            local ok, res = pcall(v[2])
            log(("strategy3 createItem(%s) -> ok=%s res=%s"):format(v[1], tostring(ok), tostring(res)))
            if ok and res and grant(res, "createItem 6-arg") then log("DONE") return end
        end
    end

    -- ---- STRATEGY 4: copyItem from an existing Item ----
    local okW, weapon = pcall(function() return inv:getSecondaryWeapon() end)
    if okW and weapon then
        for _, v in ipairs({
            { "copyItem(item)", function() return factory:copyItem(weapon) end },
            { "copyItem()",     function() return factory:copyItem() end },
        }) do
            local ok, res = pcall(v[2])
            log(("strategy4 %s -> ok=%s res=%s"):format(v[1], tostring(ok), tostring(res)))
            if ok and res and grant(res, v[1]) then log("DONE") return end
        end
    end

    log("no strategy produced a grantable Item -- see errors above")
    log("============ END MINT FINAL ============")
end)

log("mint-final probe armed")
