-- ============================================================================
-- MINT: solve the last argument slot
--
-- Signature reconstructed purely from error messages (the docs were useless):
--   createItem(gameData, hand, gameData_or_nil, ?, NUMBER, ?)
--     arg#2 GameData  ACCEPTED  (the item type -- Dried Fish)
--     arg#3 hand      ACCEPTED  (owner handle; all 3 sources worked)
--     arg#4 GameData  optional  (nil passed cleanly)
--     arg#5 ?         nil passed cleanly
--     arg#6 NUMBER    <- we sent `false`, it demanded a number
--     arg#7 ?         never reached
--
-- So: put a number in slot 5 (Lua-side) and vary the rest.
-- Run from the console -- no restart needed:
--   dofile("mods/KenshiLua/scripts/init/16_mint_solve.lua")
-- ============================================================================

local TAG = "[MINT4] "
local function log(m) print(TAG .. tostring(m)) end

local okC, char = pcall(function() return getSelectedCharacter() end)
if not okC or not char then log("select a character first") return end

local okCon, container = pcall(function() return char:getFaction():getData().sourceContainer end)
if not okCon or not container then log("no container") return end

local okF, fish = pcall(function() return container:getDataByName("Dried Fish", 4) end)
if not okF or not fish then log("no Dried Fish GameData") return end

local okI, inv = pcall(function() return char:getInventory() end)
if not okI or not inv then log("no inventory") return end

local okH, hand = pcall(function() return inv:getHandle() end)
if not okH or not hand then log("no hand") return end

local factory = getRootObjectFactory()
log("========== MINT SOLVE ==========")

local function grant(item, how)
    local ok, res = pcall(function() return inv:addItem(item, 1, true, false) end)
    log(("  GRANT -> ok=%s res=%s"):format(tostring(ok), tostring(res)))
    if ok and res then
        log("*** DRIED FISH IN INVENTORY via " .. how .. " ***")
        return true
    end
    return false
end

-- Slot 5 (Lua) must be a number. Sweep plausible meanings -- level, quality,
-- quantity -- and vary slots 3/4/6 around it.
local shapes = {
    { "gd,hand,nil,nil,0,0",     function() return factory:createItem(fish, hand, nil, nil, 0, 0) end },
    { "gd,hand,nil,nil,1,0",     function() return factory:createItem(fish, hand, nil, nil, 1, 0) end },
    { "gd,hand,nil,nil,1,1",     function() return factory:createItem(fish, hand, nil, nil, 1, 1) end },
    { "gd,hand,nil,nil,-1,0",    function() return factory:createItem(fish, hand, nil, nil, -1, 0) end },
    { "gd,hand,nil,nil,0,1",     function() return factory:createItem(fish, hand, nil, nil, 0, 1) end },
    { "gd,hand,nil,false,0,0",   function() return factory:createItem(fish, hand, nil, false, 0, 0) end },
    { "gd,hand,nil,true,1,0",    function() return factory:createItem(fish, hand, nil, true, 1, 0) end },
    { "gd,hand,fish,nil,0,0",    function() return factory:createItem(fish, hand, fish, nil, 0, 0) end },
    { "gd,hand,fish,nil,1,0",    function() return factory:createItem(fish, hand, fish, nil, 1, 0) end },
    { "gd,hand,nil,nil,0,false", function() return factory:createItem(fish, hand, nil, nil, 0, false) end },
    { "gd,hand,nil,nil,0,nil",   function() return factory:createItem(fish, hand, nil, nil, 0, nil) end },
}

for _, s in ipairs(shapes) do
    local ok, res = pcall(s[2])
    log(("createItem(%s) -> ok=%s res=%s"):format(s[1], tostring(ok), tostring(res)))
    if ok and res then
        log("*** createItem RETURNED AN ITEM ***")
        if grant(res, s[1]) then
            log("========== SOLVED ==========")
            return
        end
    end
end

log("no shape yielded an Item -- errors above name the next expected type")
log("========== END ==========")
