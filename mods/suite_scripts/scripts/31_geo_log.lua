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
-- TOUR WORKFLOW -- FOUND LIVE 2026-08-18: the first version required typing
-- a name/category/note into the call itself, which meant hand-editing Lua
-- syntax at every single stop -- real friction for anyone not fluent in it,
-- and it produced a genuine error when tried without the required name arg.
-- Redesigned around what Greg actually asked for: ONE command, identical
-- every time, nothing to edit, ever:
--
--     Geo.mark()
--
-- Run that exact line at every town, major or minor, close enough to see it
-- but not necessarily inside it -- a rough position is all the site table
-- needs. It prints "MARK #N" plus the position and does nothing else.
-- Afterward, just say in chat, in order, what each numbered mark was --
-- "1 was my house, 2 was the first western hiver town, 3 was..." -- that
-- narration is the label; the tool no longer needs one.
--
--   Geo.list()   -- print everything captured so far, one line per mark
--   Geo.count()  -- how many marks exist right now
--   Geo.clear()  -- wipe and start over (rarely needed)
--
-- After the tour: python tools/readlog.py --tag GEO pulls every captured
-- line back out in one place, matched up against the chat narration to
-- build NPC_ECONOMY.md's site table.
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

-- Geo.mark() -- zero arguments, always. Nothing to type, nothing to get
-- wrong. Run the exact same line at every stop; tell me what each numbered
-- mark was afterward, in chat, in order.
function Geo.mark()
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

    local entry = { x = pos.x, y = pos.y, z = pos.z }
    Geo.marks[#Geo.marks + 1] = entry

    log(("MARK #%d  x=%.1f y=%.1f z=%.1f"):format(#Geo.marks, entry.x, entry.y, entry.z))
    return entry
end

function Geo.count()
    log(("%d mark(s) captured so far"):format(#Geo.marks))
    return #Geo.marks
end

function Geo.list()
    if #Geo.marks == 0 then
        log("nothing captured yet -- Geo.mark() at each stop")
        return
    end
    log(("=== %d mark(s) ==="):format(#Geo.marks))
    for i, e in ipairs(Geo.marks) do
        log(("%3d  x=%.1f y=%.1f z=%.1f"):format(i, e.x, e.y, e.z))
    end
    log("=== end ===")
end

function Geo.clear()
    local n = #Geo.marks
    Geo.marks = {}
    log(("cleared %d mark(s)"):format(n))
end

log("31_geo_log loaded -- Geo.mark() (same exact command every stop) / .list() / .count() / .clear()")
log("read-only, zero world-state writes -- safe at every town regardless of hostility")
