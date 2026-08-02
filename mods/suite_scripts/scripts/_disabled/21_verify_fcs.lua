-- ============================================================================
-- VERIFY the FCS items authored in KenshiOverhaulSuite.mod
--
-- Greg's stringIDs:  10=Raw Fish  11=Small Fish  12=Cooked Fish  14=Burnt (Fish?)
-- Our Lua looks items up BY NAME, so the exact in-game names matter more than
-- the ids. This tries every plausible spelling and reports what actually
-- resolves, so we wire the real names rather than assumed ones.
--
--   dofile("mods/KenshiLua/scripts/init/21_verify_fcs.lua")
-- ============================================================================
local TAG = "[VERIFY] "
local function log(m) print(TAG .. tostring(m)) end

local CANDIDATES = {
    "Raw Fish", "Small Fish", "Cooked Fish",
    "Burnt Fish", "Burnt Meat", "Burned Fish", "Burned Meat",
}

local okC, char = pcall(function() return getSelectedCharacter() end)
if not okC or not char then log("select a character first") return end
local okCon, container = pcall(function()
    return char:getFaction():getData().sourceContainer end)
if not okCon or not container then log("no container") return end

log("========== FCS ITEM VERIFY ==========")
local hits = 0
for _, name in ipairs(CANDIDATES) do
    local found = false
    for c = 0, 40 do
        local ok, gd = pcall(function() return container:getDataByName(name, c) end)
        if ok and gd then
            local okS, sid = pcall(function() return gd.stringID end)
            log(("FOUND  %-14s cat=%-2d stringID=%s"):format(name, c, okS and tostring(sid) or "?"))
            hits = hits + 1
            found = true
            break
        end
    end
    if not found then log(("  --   %-14s not found"):format(name)) end
end
log(("========== %d/%d resolved =========="):format(hits, #CANDIDATES))
if hits == 0 then
    log("NOTHING resolved -- is KenshiOverhaulSuite.mod enabled and the game restarted?")
end
