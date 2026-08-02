-- ============================================================================
-- Find item 14 (the burnt one). Item 12 turned out to be "Cooked fish" --
-- lowercase f -- so getDataByName is CASE-SENSITIVE and item 14 is very likely
-- "Burnt fish" by the same pattern. Sweep casings and synonyms.
--   dofile("mods/KenshiLua/scripts/init/23_find_burnt.lua")
-- ============================================================================
local TAG = "[BURNT] "
local function log(m) print(TAG .. tostring(m)) end

local NAMES = {
    "Burnt fish", "Burnt Fish", "burnt fish", "BURNT FISH",
    "Burnt meat", "Burnt Meat", "burnt meat",
    "Burned fish", "Burned Fish", "burned fish",
    "Burned meat", "Burned Meat",
    "Charred fish", "Charred Fish", "Ruined fish", "Ruined Fish",
    "Spoiled fish", "Spoiled Fish", "Bad fish", "Burnt food", "Burnt Food",
}

local okC, char = pcall(function() return getSelectedCharacter() end)
if not okC or not char then log("select a character first") return end
local okCon, container = pcall(function()
    return char:getFaction():getData().sourceContainer end)
if not okCon or not container then log("no container") return end

log("========== BURNT ITEM SEARCH ==========")
local found = false
for _, name in ipairs(NAMES) do
    for c = 0, 40 do
        local ok, gd = pcall(function() return container:getDataByName(name, c) end)
        if ok and gd then
            local okS, sid = pcall(function() return gd.stringID end)
            log(("FOUND  %q  cat=%d  stringID=%s"):format(name, c, okS and tostring(sid) or "?"))
            found = true
            break
        end
    end
end
if not found then
    log("none matched -- open FCS and read item 14's exact Name field")
    log("(remember: lookup is CASE-SENSITIVE, and item 12 was 'Cooked fish')")
end
log("========== END ==========")
