-- ============================================================================
-- SPAWN CAPABILITY PROBE  (manual only -- lives in scripts/, NOT scripts/init/)
--
-- Answers a different question than 27_projector_probe.lua: not "can we drive
-- an EXISTING vanilla character", but "can we create our OWN character, one
-- we hold a direct Lua reference to from the moment it exists" -- sidestepping
-- the getSelectedCharacter() problem entirely, since a spawned object's
-- reference never depends on player squad-roster selection at all.
--
-- WHY THIS EXISTS (2026-08-12): Greg's own live testing found that vanilla
-- NPCs can be clicked/toggled in-world but are not truly SELECTABLE the way
-- squad members are -- getSelectedCharacter() reads
-- PlayerInterface.selectedCharacter, which structurally can only ever return
-- one of the player's own characters (see docs/architecture/SPINE.md's
-- "getSelectedCharacter() can only ever return squad" finding). Every
-- Projector test this project has run was therefore squad-scoped whether
-- intended or not. Rather than keep fighting that, this probe asks: can we
-- spawn a character that is OURS from creation, with no selection step
-- needed at all?
--
-- ONE THING RULED OUT ALREADY, DO NOT TRY IT:
-- PlayerInterface.playerCharacters (the squad roster) is typed
-- `lektor<Character*>` in BindingsReference.md. SPINE.md's own Danger List
-- already states: "Any lektor<T*> / std:: / vector<>/ map<> member -- HARD
-- CRASH (confirmed x2)." Writing a spawned character directly into that
-- field to "add them to the roster" is precisely the class of raw
-- container write already known to crash this game. Never call it.
--
-- WHAT LOOKS SAFER, PER BindingsReference.md's RootObjectFactory section
-- (all real bound METHODS, not raw container writes -- the C++ side owns
-- whatever internal bookkeeping a spawn needs, the same reason this
-- project prefers an existing API over hand-rolled internals):
--   RootObjectFactory:createRandomCharacter(position, age) -> RootObject
--   RootObjectFactory:createRandomSquad(position, maxnum, maparea,
--       permanentsquad, sizeMultiplier, squadType, isJustARefresh) -> Platoon
-- This is the SAME machinery vanilla itself uses to populate the world with
-- wandering NPCs, traders, and bandit squads -- not a hack, a real spawn
-- path. "Random" means random race/stats/looks; full custom authorship (our
-- own classes) is a later question once spawning itself is proven to work
-- at all.
--
-- THREE PHASES, RISK-ORDERED:
--   0. CAPABILITY CHECK. Confirm getRootObjectFactory() exists and log which
--      of the methods above are actually bound. Read-only, zero world state
--      change, cannot fault anything of its own.
--   1. SPAWN ONE. createRandomCharacter at a position near the SELECTED
--      character (so you can see it appear) -- HIGHEST RISK step in this
--      file, a genuine world-state-changing call we have never made before.
--      Logged before/after (pcall does not catch a native crash), and the
--      returned reference is cached on Spawn._last so nothing needs
--      getSelectedCharacter() to reach it afterward.
--   2. READ BACK. Confirm the spawned object is a real, live, queryable
--      character (name, position, faction) -- proves it exists as more than
--      an opaque handle before anything else touches it.
--
-- SAFETY: phase 1 permanently adds a character to the world. There is no
-- known "undespawn" in this probe -- if it needs removing, that is a
-- question for a follow-up, not assumed solved here. Run this somewhere a
-- stray NPC is not a problem (not mid-town, not mid-combat).
--
--   dofile("mods/KenshiLua/scripts/30_spawn_probe.lua")
--   Spawn.checkCapability()      -- phase 0, always safe
--   Spawn.spawnOne()             -- phase 1, HIGHEST RISK, select a character first (for position + camera reference)
--   Spawn.describeLast()         -- phase 2, safe, reads back what spawnOne created
-- ============================================================================

local TAG = "[SPAWN-PROBE] "
local function log(m) print(TAG .. tostring(m)) end

Spawn = Spawn or {}
pcall(function() _G.Spawn = Spawn end)

-- ---------------------------------------------------------------------------
-- PHASE 0 -- CAPABILITY CHECK. Zero world-state change.
-- ---------------------------------------------------------------------------
function Spawn.checkCapability()
    log("=== SPAWN CAPABILITY CHECK (nothing will be created) ===")
    local okF, factory = pcall(function() return getRootObjectFactory() end)
    log("getRootObjectFactory() -> " .. (okF and type(factory) or ("ERROR " .. tostring(factory))))
    if not okF or not factory then
        log("cannot proceed -- no factory available")
        return false
    end
    for _, m in ipairs({ "createRandomCharacter", "createRandomSquad",
                         "createRandomUnloadedCharacter", "create" }) do
        local okM, v = pcall(function() return factory[m] end)
        log(("  %-28s %s"):format(m, okM and type(v) or "ERROR"))
    end
    log("=== end capability check ===")
    return true
end

-- ---------------------------------------------------------------------------
-- PHASE 1 -- SPAWN ONE. HIGHEST RISK: a real, permanent world-state change,
-- and a call this project has never made live before. Every step logged
-- BEFORE it runs (log-as-cursor -- pcall cannot catch a native crash, so a
-- hard fault leaves the last TRY line as the only evidence of what killed
-- it), same discipline as 27_projector_probe.lua.
--
-- Position: offset from the SELECTED character (not the spawned one --
-- there isn't one yet), so the new character appears somewhere you are
-- already looking, at your own age band rather than a guess. age=20 is a
-- plain placeholder -- adjust if a specific age matters for what you are
-- testing.
-- ---------------------------------------------------------------------------
function Spawn.spawnOne(age)
    age = tonumber(age) or 20
    log("========== SPAWN PHASE 1: createRandomCharacter ==========")

    local okC, c = pcall(function() return getSelectedCharacter() end)
    if not okC or not c then
        log("select a character first (used only for a spawn-position reference)")
        return nil
    end
    local okPos, pos = pcall(function() return c:getPosition() end)
    if not okPos or not pos then
        log("cannot read a position reference, aborting -- spawn location would be a pure guess")
        return nil
    end
    -- A few units off so the new character does not spawn exactly inside
    -- whoever it is standing next to.
    local spawnPos = { x = (pos.x or 0) + 5, y = pos.y or 0, z = pos.z or 0 }

    local okF, factory = pcall(function() return getRootObjectFactory() end)
    if not okF or not factory then
        log("no RootObjectFactory available, aborting")
        return nil
    end

    log(("TRY: factory:createRandomCharacter({x=%.1f,y=%.1f,z=%.1f}, %d)")
        :format(spawnPos.x, spawnPos.y, spawnPos.z, age))   -- LOG-AS-CURSOR: printed BEFORE the call
    local okS, spawned = pcall(function() return factory:createRandomCharacter(spawnPos, age) end)
    log(("createRandomCharacter -> %s"):format(okS and type(spawned) or ("ERROR " .. tostring(spawned))))
    if not okS or not spawned then
        log("========== END SPAWN PHASE 1 (failed) ==========")
        return nil
    end

    Spawn._last = spawned
    log("If the game is still running and this line printed, the call did not hard-crash.")
    log("LOOK AT THE SCREEN near the selected character -- is a new NPC standing there?")
    log("Reference cached in Spawn._last -- Spawn.describeLast() to read it back.")
    log("========== END SPAWN PHASE 1 ==========")
    return spawned
end

-- ---------------------------------------------------------------------------
-- PHASE 2 -- READ BACK. Confirms the spawned object is a real, queryable
-- character rather than an opaque handle, without touching anything else.
-- ---------------------------------------------------------------------------
function Spawn.describeLast()
    log("=== describing Spawn._last ===")
    local obj = Spawn._last
    if not obj then
        log("nothing spawned yet -- run Spawn.spawnOne() first")
        return
    end
    log("type: " .. type(obj))

    -- createRandomCharacter's documented return type is RootObject, which is
    -- a DIFFERENT type than Character (see the addGoal/addJob
    -- RootObject-vs-RootObjectBase distinction in SPINE.md) -- unknown yet
    -- whether Character methods (getName/getPosition) are directly callable
    -- on it, or whether it needs its own unwrap first. Try both, log
    -- honestly either way.
    local okN, name = pcall(function() return obj:getName() end)
    log("  getName()      -> " .. (okN and tostring(name) or ("ERROR " .. tostring(name))))
    local okP, pos = pcall(function() return obj:getPosition() end)
    if okP and type(pos) == "table" then
        log(("  getPosition()  -> x=%s y=%s z=%s"):format(tostring(pos.x), tostring(pos.y), tostring(pos.z)))
    else
        log("  getPosition()  -> " .. (okP and type(pos) or ("ERROR " .. tostring(pos))))
    end
    local okFac, fac = pcall(function() return obj:getFaction() end)
    log("  getFaction()   -> " .. (okFac and type(fac) or ("ERROR " .. tostring(fac))))

    if not okN and not okP then
        log("  neither Character method worked directly -- obj may need an unwrap")
        log("  step first (same shape as hand:getRootObject()/getRootObjectBase()).")
        log("  Try: obj.getRootObjectBase and obj:getRootObjectBase(), or inspect")
        log("  available keys/methods on obj directly.")
    end
    log("=== end describe ===")
end

log("30_spawn_probe loaded.")
log("  Spawn.checkCapability()   -- phase 0, always safe, no world change")
log("  Spawn.spawnOne(age)       -- phase 1, HIGHEST RISK, permanent world-state change, select a character first")
log("  Spawn.describeLast()      -- phase 2, safe, reads back what spawnOne created")
log("NEVER write to PlayerInterface.playerCharacters directly -- lektor<T*>, the confirmed hard-crash class.")
