-- ============================================================================
-- GEO LOG  (manual only -- lives in scripts/, NOT scripts/init/)
--
-- Captures real map coordinates for docs/architecture/NPC_ECONOMY.md's open
-- item: "needs Greg -- real site coordinates (per city, per resource kind)".
-- No guessing, no invented geography -- this reads the SELECTED character's
-- real position live and files it under whatever label you give it.
--
-- ENTIRELY READ-ONLY. getPosition() is a call this project has used
-- successfully hundreds of times this session with zero crashes (Fishing's
-- readPos, testBar's placement, every relocationTeleport target). This file
-- makes NO writes, calls NO addJob/addGoal/addOrder, changes NOTHING in the
-- world -- it cannot fail the way those calls can, and needs no pcall-wrapped
-- log-as-cursor discipline because there is no risky call to bracket.
--
-- TOUR WORKFLOW
--   At each town (major or minor), close enough to see it but not
--   necessarily inside it -- a rough position is all the site table needs,
--   getting mauled by hostile guards to shave off a few metres of accuracy
--   is not worth it:
--     Geo.mark("Squin", "major", "farming, western hivers allied")
--     Geo.mark("Some Satellite Town", "minor", "near Squin, looked like ore")
--   category is a free string -- "major"/"minor" is a natural fit but use
--   whatever reads clearly; it is never validated or gated.
--   note is freeform -- faction, hostility, what the terrain looked like,
--   anything worth remembering later. Optional.
--
--   Geo.list()   -- print everything captured so far, one line per mark
--   Geo.count()  -- how many marks exist right now
--   Geo.clear()  -- wipe and start over (rarely needed)
--
-- After the tour: python tools/readlog.py --tag GEO pulls every captured
-- line back out in one place, ready to fold into NPC_ECONOMY.md's site
-- table.
-- ============================================================================

local TAG = "[GEO] "
local function log(m) print(TAG .. tostring(m)) end

Geo = Geo or {}
pcall(function() _G.Geo = Geo end)

Geo.marks = Geo.marks or {}

local function readPos(character)
    local ok, p = pcall(function() return character:getPosition() end)
    if not ok or type(p) ~= "table" then return nil end
    local x = p.x or p[1]
    local y = p.y or p[2]
    local z = p.z or p[3]
    if type(x) ~= "number" or type(z) ~= "number" then return nil end
    return { x = x, y = y or 0, z = z }
end

-- Geo.mark("Squin", "major", "farming, western hivers allied")
function Geo.mark(name, category, note)
    if type(name) ~= "string" or name == "" then
        log("give it a name: Geo.mark(\"Town Name\", \"major\"|\"minor\", \"optional note\")")
        return nil
    end
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then
        log("select a character first (position is read from whoever is selected)")
        return nil
    end
    local pos = readPos(c)
    if not pos then
        log("could not read a position -- nothing recorded")
        return nil
    end

    local entry = {
        name = name,
        category = (type(category) == "string" and category ~= "") and category or "?",
        note = (type(note) == "string") and note or "",
        x = pos.x, y = pos.y, z = pos.z,
    }
    Geo.marks[#Geo.marks + 1] = entry

    log(("MARK #%d  %-28s [%s]  x=%.1f y=%.1f z=%.1f%s")
        :format(#Geo.marks, entry.name, entry.category, entry.x, entry.y, entry.z,
                entry.note ~= "" and ("  -- " .. entry.note) or ""))
    return entry
end

function Geo.count()
    log(("%d mark(s) captured so far"):format(#Geo.marks))
    return #Geo.marks
end

function Geo.list()
    if #Geo.marks == 0 then
        log("nothing captured yet -- Geo.mark(\"Town Name\", \"major\"|\"minor\", \"note\")")
        return
    end
    log(("=== %d mark(s) ==="):format(#Geo.marks))
    for i, e in ipairs(Geo.marks) do
        log(("%3d  %-28s [%s]  x=%.1f y=%.1f z=%.1f%s")
            :format(i, e.name, e.category, e.x, e.y, e.z,
                    e.note ~= "" and ("  -- " .. e.note) or ""))
    end
    log("=== end ===")
end

function Geo.clear()
    local n = #Geo.marks
    Geo.marks = {}
    log(("cleared %d mark(s)"):format(n))
end

log("31_geo_log loaded -- Geo.mark(name, category, note) / .list() / .count() / .clear()")
log("read-only, zero world-state writes -- safe at every town regardless of hostility")
