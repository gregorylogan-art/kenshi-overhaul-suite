-- ============================================================================
-- FISH HUNT 2: one-word spellings + sea life + failure products.
-- Greg reports "thinfish" and "grandfish" exist and are EXPENSIVE -- the first
-- hunt used two-word spellings and missed them. Knowing what already exists
-- decides what we author in FCS versus what we reuse.
--   dofile("mods/KenshiLua/scripts/init/20_fish_hunt2.lua")
-- ============================================================================
local TAG = "[HUNT2] "
local function log(m) print(TAG .. tostring(m)) end

local NAMES = {
    -- one-word forms the first sweep missed
    "Thinfish", "thinfish", "ThinFish", "Grandfish", "grandfish", "GrandFish",
    "Riverfish", "Bonefish", "Catfish", "Swampfish", "Cavefish",
    -- sea life Greg wants in the table
    "Lobster", "Octopus", "Calimari", "Calamari", "Squid", "Crab", "Shrimp",
    "Eel", "Clam", "Oyster",
    -- cooked / processed
    "Cooked Fish", "Cooked Lobster", "Cooked Calimari", "Sushi", "Chum",
    "Burnt Meat", "Burned Meat", "Charred Meat",
    -- odd variants
    "Small Fish", "Strange Fish", "Brilliant Fish", "Sick Fish", "Dead Fish",
    "Robot Fish", "Robotic Fish",
    -- anchors we already know resolve
    "Dried Fish", "Raw Meat",
}

local okC, char = pcall(function() return getSelectedCharacter() end)
if not okC or not char then log("select a character first") return end
local okCon, container = pcall(function()
    return char:getFaction():getData().sourceContainer end)
if not okCon or not container then log("no container") return end

log("========== FISH HUNT 2 ==========")
local found = 0
for _, name in ipairs(NAMES) do
    for c = 0, 40 do
        local ok, gd = pcall(function() return container:getDataByName(name, c) end)
        if ok and gd then
            local okS, sid = pcall(function() return gd.stringID end)
            log(("FOUND  %-18s cat=%-2d stringID=%s"):format(name, c, okS and tostring(sid) or "?"))
            found = found + 1
            break
        end
    end
end
log(("========== %d found =========="):format(found))
