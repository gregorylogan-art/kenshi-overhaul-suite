-- ============================================================================
-- TARGETED PROBE: how do we mint/grant an Item?
--
-- The fishing loop works end to end except the grant. The failure was not a
-- dead end, it was a spec:
--
--   inv:addItem(1, true, false)
--     -> "bad argument #2 to '?' (KenshiLua.Item expected, got number)"
--
-- In Lua `obj:addItem(x)` passes obj as #1 and x as #2, so the REAL signature
-- starts with an Item:
--
--   Inventory:addItem(item, quantity, dropOnFail, destroyOnFail)
--
-- The docs claim `(quantity, dropOnFail, destroyOnFail)` -- wrong, exactly like
-- the other 29 signature errors the sweep found. So the open question is only:
-- WHERE DOES AN `Item` COME FROM?
--
-- Rather than keep reading unreliable docs, this INTROSPECTS THE LIVE OBJECTS:
-- enumerate what getRootObjectFactory() and an existing Item actually expose.
-- Runtime truth beats generated documentation.
--
-- SAFE: enumeration and reads only. The one mutating call (addItem with a real
-- Item) is the exact thing we must learn, is pcall-wrapped, and at worst
-- duplicates an item already in your inventory.
-- ============================================================================

local TAG = "[ITEM] "
local function log(m) print(TAG .. tostring(m)) end

-- Enumerate an object's callable surface. KenshiLua userdata usually carries a
-- metatable with __index holding the bound methods; walk both.
local function dumpSurface(label, obj, limit)
    if obj == nil then log(label .. ": nil") return end
    log(("%s: %s"):format(label, tostring(obj)))
    local seen, n = {}, 0

    local function emit(src, k, v)
        if seen[k] then return end
        seen[k] = true
        n = n + 1
        if n <= (limit or 60) then
            log(("   [%s] %s : %s"):format(src, tostring(k), type(v)))
        end
    end

    local okDirect = pcall(function()
        for k, v in pairs(obj) do emit("direct", k, v) end
    end)
    if not okDirect then log("   (not directly iterable)") end

    local mt = getmetatable(obj)
    if type(mt) == "table" then
        pcall(function() for k, v in pairs(mt) do emit("meta", k, v) end end)
        local idx = rawget(mt, "__index")
        if type(idx) == "table" then
            pcall(function() for k, v in pairs(idx) do emit("__index", k, v) end end)
        end
    end
    log(("   -> %d member(s) total"):format(n))
end

local fired = false
registerHandler("onCharsUpdate", function()
    if fired then return end

    local ok, char = pcall(function() return getSelectedCharacter() end)
    if not ok or not char then return end
    fired = true

    log("=================== ITEM ROUTE PROBE ===================")

    -- 1. What does the factory actually expose? (global exists; docs say nothing)
    local okF, factory = pcall(function() return getRootObjectFactory() end)
    dumpSurface("getRootObjectFactory()", okF and factory or nil, 80)

    -- 2. Get a REAL Item to learn its type and to test addItem's signature.
    local okI, inv = pcall(function() return char:getInventory() end)
    if not okI or not inv then log("no inventory") return end

    local specimenItem
    local okW, weapon = pcall(function() return inv:getSecondaryWeapon() end)
    if okW and weapon then
        specimenItem = weapon
        log("specimen Item obtained via inv:getSecondaryWeapon()")
    end
    dumpSurface("specimen Item", specimenItem, 40)

    -- 3. What is in getAllItems()? (returned userdata -- container or iterator?)
    local okA, all = pcall(function() return inv:getAllItems() end)
    if okA then dumpSurface("inv:getAllItems()", all, 30) end

    -- 4. THE TEST: does addItem accept an Item first?
    if specimenItem then
        local ok1, r1 = pcall(function() return inv:addItem(specimenItem, 1, true, false) end)
        log(("addItem(item,1,true,false) -> ok=%s res=%s"):format(tostring(ok1), tostring(r1)))
        if not ok1 then
            local ok2, r2 = pcall(function() return inv:addItem(specimenItem) end)
            log(("addItem(item) -> ok=%s res=%s"):format(tostring(ok2), tostring(r2)))
        end
    else
        log("no specimen Item -- cannot test addItem signature")
    end

    -- 5. GameData: sibling calls demand it, so it likely identifies item TYPES.
    local okG, gd = pcall(function() return char:getData() end)
    dumpSurface("character:getData() [GameData]", okG and gd or nil, 40)

    log("=================== END ITEM PROBE ===================")
end)

log("item route probe armed")
