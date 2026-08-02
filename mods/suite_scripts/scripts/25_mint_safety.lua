-- ============================================================================
-- MINT SAFETY PROBE  (manual only -- lives in scripts/, NOT scripts/init/)
--
-- Investigates issue #21: the character broke twice with an inventory GUI that
-- would not open. Suspicion is that category-3 (clothing/misc) items minted via
--     createItem(gd, hand, nil, nil, LEVEL=0, nil)
-- are MALFORMED -- complete enough for addItem to accept, not complete enough
-- for the inventory UI to render.
--
-- This creates candidate items and INSPECTS them WITHOUT granting, comparing a
-- known-good category-4 food item against a suspect category-3 one. If a
-- required field is blank on the cat-3 item, that is very likely what the GUI
-- chokes on.
--
-- SAFE: creates items and reads scalar fields only. Nothing is added to any
-- inventory, so nothing can reach the UI or the save. Container-typed members
-- are never touched (they hard-crash the game).
--
--   dofile("mods/KenshiLua/scripts/25_mint_safety.lua")
-- ============================================================================

local TAG = "[MINTSAFE] "
local function log(m) print(TAG .. tostring(m)) end

local okC, char = pcall(function() return getSelectedCharacter() end)
if not okC or not char then log("select a character first") return end
local okCon, container = pcall(function()
    return char:getFaction():getData().sourceContainer end)
if not okCon or not container then log("no container") return end
local okI, inv = pcall(function() return char:getInventory() end)
if not okI or not inv then log("no inventory") return end
local okH, hand = pcall(function() return inv:getHandle() end)
if not okH or not hand then log("no hand") return end

local factory = getRootObjectFactory()

-- Scalar-only inspection. Anything container-typed is deliberately excluded.
local SCALARS = {
    "getModelName", "getLevel", "getClassType", "getVisible",
    "getCraftTime", "getActiveModIndex",
}

local function inspect(item, label)
    if not item then log(label .. ": nil") return end
    log(label .. ": " .. tostring(item))
    for _, m in ipairs(SCALARS) do
        if item[m] then
            local ok, v = pcall(function() return item[m](item) end)
            log(("    %-18s = %s"):format(m, ok and tostring(v) or ("ERR " .. tostring(v))))
        else
            log(("    %-18s ABSENT"):format(m))
        end
    end
end

local function lookup(name, cat)
    local ok, gd = pcall(function() return container:getDataByName(name, cat) end)
    return ok and gd or nil
end

log("========== MINT SAFETY ==========")

-- 1. KNOWN GOOD: category-4 food that has displayed correctly all session.
local foodGd = lookup("Small Fish", 4) or lookup("Dried Fish", 4)
if foodGd then
    local ok, item = pcall(function()
        return factory:createItem(foodGd, hand, nil, nil, 0, nil) end)
    inspect(ok and item or nil, "GOOD  cat4 food @level0")
else
    log("no food GameData to compare against")
end

-- 2. SUSPECT: category-3 clothing, the class present when the GUI broke.
local clothGd = lookup("Straw Hat", 3) or lookup("Rag Loincloth", 3)
if clothGd then
    for _, lvl in ipairs({ 0, 1, -1 }) do
        local ok, item = pcall(function()
            return factory:createItem(clothGd, hand, nil, nil, lvl, nil) end)
        inspect(ok and item or nil, ("SUSPECT cat3 cloth @level%d"):format(lvl))
    end
else
    log("no cat-3 GameData found to test")
end

-- 3. Does passing the item's own GameData into the optional slots help?
if clothGd then
    local ok, item = pcall(function()
        return factory:createItem(clothGd, hand, clothGd, clothGd, 0, nil) end)
    inspect(ok and item or nil, "cat3 with GameData in both optional slots")
end

log("")
log("READ THE getModelName LINES. A good item should report a real mesh name.")
log("If the cat-3 item returns empty/nil where the food item returns a name,")
log("that missing model is almost certainly what the inventory GUI cannot draw.")
log("========== END ==========")
