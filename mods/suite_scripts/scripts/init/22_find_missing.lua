-- ============================================================================
-- FIND the two FCS items that did not resolve.
--
-- Raw Fish (10-) and Small Fish (11-) resolve at category 4 -- both cloned from
-- Raw Meat. Cooked Fish (12-) and Burnt (14-) were cloned from COOKED MEAT and
-- do not resolve, so either:
--   (a) they sit in a category above the 0-40 sweep, or
--   (b) their in-game names differ from what we are guessing, or
--   (c) those two did not save.
--
-- Widens the category sweep to 0-120 and tries many more spellings.
--   dofile("mods/KenshiLua/scripts/init/22_find_missing.lua")
-- ============================================================================
local TAG = "[FIND] "
local function log(m) print(TAG .. tostring(m)) end

local NAMES = {
    -- cooked variants
    "Cooked Fish", "cooked fish", "CookedFish", "Cooked fish",
    "Fish Cooked", "Grilled Fish", "Fried Fish",
    -- burnt variants
    "Burnt Fish", "burnt fish", "Burnt Meat", "Burned Fish", "Burned Meat",
    "Burnt", "Charred Fish", "Burnt Food",
    -- what did they clone FROM? confirm it exists and where
    "Cooked Meat", "Meat Wrap", "Foodcube", "Dustwich", "Ration Pack",
    -- known-good controls
    "Raw Fish", "Small Fish",
}

local okC, char = pcall(function() return getSelectedCharacter() end)
if not okC or not char then log("select a character first") return end
local okCon, container = pcall(function()
    return char:getFaction():getData().sourceContainer end)
if not okCon or not container then log("no container") return end

log("========== WIDE SEARCH (categories 0-120) ==========")
local hits = 0
for _, name in ipairs(NAMES) do
    for c = 0, 120 do
        local ok, gd = pcall(function() return container:getDataByName(name, c) end)
        if ok and gd then
            local okS, sid = pcall(function() return gd.stringID end)
            log(("FOUND  %-16s cat=%-3d stringID=%s"):format(name, c, okS and tostring(sid) or "?"))
            hits = hits + 1
            break
        end
    end
end
log(("========== %d found =========="):format(hits))
log("Anything absent here either has a different name in FCS or did not save.")
log("Open FCS and read the exact Name field of items 12- and 14-.")
