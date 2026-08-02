-- ============================================================================
-- FISH HUNT: find every fish item in the game data.
--
-- Greg reports THREE fish icons exist in Kenshi; we have confirmed only
-- "Dried Fish" (category 4). Raw/thin fish would let the loop be:
--     catch RAW fish -> must COOK it -> chance to burn -> edible
-- which keeps fishing from being free money.
--
-- Sweeps fish-flavoured names across every category (2=weapons, 3=clothing,
-- 4=food/materials confirmed; others unknown, so scan them all).
--
-- Run from the console -- no restart:
--   dofile("mods/KenshiLua/scripts/init/17_fish_hunt.lua")
-- ============================================================================

local TAG = "[HUNT] "
local function log(m) print(TAG .. tostring(m)) end

local NAMES = {
    -- raw / uncooked
    "Raw Fish", "Thin Fish", "Fish", "Fresh Fish", "River Fish", "Riverfish",
    "Small Fish", "Big Fish", "Cave Fish", "Bonefish", "Catfish", "Fishmeat",
    "Fish Meat", "Raw Thin Fish", "Whole Fish",
    -- cooked / preserved
    "Dried Fish", "Cooked Fish", "Grilled Fish", "Smoked Fish", "Salted Fish",
    "Fish Stew", "Fried Fish", "Baked Fish", "Fish Cube",
    -- comparison anchors: Greg wants raw fish to match Raw Meat's stats
    "Raw Meat", "Cooked Meat", "Dried Meat", "Foodcube",
}

local okC, char = pcall(function() return getSelectedCharacter() end)
if not okC or not char then log("select a character first") return end

local okCon, container = pcall(function()
    return char:getFaction():getData().sourceContainer
end)
if not okCon or not container then log("no GameDataContainer") return end

log("========== FISH HUNT ==========")
local found = 0
for _, name in ipairs(NAMES) do
    local hit, cat, sid = nil, nil, nil
    for c = 0, 40 do
        local ok, gd = pcall(function() return container:getDataByName(name, c) end)
        if ok and gd then
            hit, cat = gd, c
            local okS, s = pcall(function() return gd.stringID end)
            sid = okS and s or "?"
            break
        end
    end
    if hit then
        found = found + 1
        log(("FOUND  %-16s category=%-2d stringID=%s"):format(name, cat, tostring(sid)))
    end
end
log(("========== %d found =========="):format(found))
log("(names not listed above do not exist under that spelling)")
