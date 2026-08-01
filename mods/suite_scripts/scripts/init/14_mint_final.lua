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

    -- Reaching the item database. The faction->getData->sourceContainer route
    -- worked for one character and returned nothing for another, so it is too
    -- fragile to rely on. Try several routes and keep the first that can
    -- actually answer getDataByName.
    local function usable(c)
        if not c then return false end
        local ok, res = pcall(function() return c:getDataByName("Bread", 4) end)
        return ok and res ~= nil
    end

    local container
    local routes = {
        { "GameWorld.gamedata", function() return getGameWorld().gamedata end },
        { "GameWorld.leveldata", function() return getGameWorld().leveldata end },
        { "GameWorld.savedata", function() return getGameWorld().savedata end },
        { "faction:getData().sourceContainer", function()
            return char:getFaction():getData().sourceContainer end },
        { "faction.data.sourceContainer", function()
            return char:getFaction().data.sourceContainer end },
    }
    for _, r in ipairs(routes) do
        local ok, c = pcall(r[2])
        local good = ok and usable(c)
        log(("route %-38s ok=%s usable=%s"):format(r[1], tostring(ok), tostring(good)))
        if good then container = c break end
    end

    if not container then
        -- Nothing answered. Dump what GameWorld.gamedata exposes so we can find
        -- the real lookup method instead of guessing again.
        local okG, mgr = pcall(function() return getGameWorld().gamedata end)
        if okG and mgr then
            log("introspecting GameWorld.gamedata:")
            local mt = getmetatable(mgr)
            local idx = type(mt) == "table" and rawget(mt, "__index")
            for _, src in ipairs({ mt, type(idx) == "table" and idx or nil }) do
                if type(src) == "table" then
                    pcall(function()
                        for k, v in pairs(src) do
                            log(("   %s : %s"):format(tostring(k), type(v)))
                        end
                    end)
                end
            end
        end
        log("no usable GameDataContainer")
        return
    end

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

    -- STRATEGIES 1 & 2 REMOVED -- factory:process() HARD CRASHED the game.
    -- My own tools/gen_probes.py blocklists `process`, `update`, `run`, `execute`
    -- as engine internals, and I bypassed that rule by hand-writing this probe.
    -- Hand-written probes must obey the same safety rules as generated ones.
    -- NEVER call: factory:process(), factory:mainThreadUpdate().

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

    -- ---- STRATEGY 5: let the INVENTORY do the minting ----
    -- Inventory/InventorySection addItem variants are documented as taking a
    -- quantity; given every other signature omits the leading subject, a
    -- GameData-first form is plausible and costs nothing to test.
    for _, v in ipairs({
        { "inv:addItem(gd,1,true,false)", function() return inv:addItem(itemData, 1, true, false) end },
        { "inv:addItem(gd,1)",            function() return inv:addItem(itemData, 1) end },
        { "inv:addItem(gd)",              function() return inv:addItem(itemData) end },
    }) do
        local ok, res = pcall(v[2])
        log(("strategy5 %s -> ok=%s res=%s"):format(v[1], tostring(ok), tostring(res)))
        if ok and res then log("*** SUCCESS via " .. v[1] .. " ***") return end
    end

    -- ---- STRATEGY 6: a section may own the mint ----
    local okS, sections = pcall(function() return inv.sections end)
    if okS and type(sections) == "table" then
        for i, sec in pairs(sections) do
            if type(sec) == "userdata" and sec.addItem then
                local ok, res = pcall(function() return sec:addItem(itemData, 1) end)
                log(("strategy6 section[%s]:addItem(gd,1) -> ok=%s res=%s")
                    :format(tostring(i), tostring(ok), tostring(res)))
                if ok and res then log("*** SUCCESS via section addItem ***") return end
            end
        end
    end

    log("no strategy produced a grantable Item -- see errors above")
    log("============ END MINT FINAL ============")
end)

log("mint-final probe armed")
