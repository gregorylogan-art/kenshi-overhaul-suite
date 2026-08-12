-- ============================================================================
-- PROJECTOR CAPABILITY PROBE  (manual only -- lives in scripts/, NOT scripts/init/)
--
-- Answers the single biggest open question blocking #28/#33/#34 and everything
-- downstream of them (#25, #46, #49, #50): can Lua actually drive an NPC
-- through a job/task, or is "verified hooks" in those issues just a doc claim
-- that was never run? See docs/architecture/SPINE.md's "OPEN: NPC job/task
-- assignment" section for the full writeup this probe tests.
--
-- 2026-08-10 UPDATE -- found `third_party/KenshiLua/docs/CallbacksReference.md`,
-- a dedicated event-callback reference distinct from BindingsReference.md
-- (methods/fields only), which neither prior pass had checked. It resolves
-- addJob's real signature with much higher confidence than either doc or
-- header alone, straight from the compiled hook's own C++ dispatcher:
--   void CallCharacterAddJobCallbacks(Character* character, int task,
--       RootObject* subject, bool shift, bool addDontClear, const Vector3& location)
-- i.e. the REAL call is addJob(task, subject, shift, addDontClear, location) --
-- BindingsReference.md's doc entry was not wrong about order so much as
-- MISSING the `subject` parameter entirely. Phase 3 below now tries this
-- shape first.
--
-- It also confirms onCharacterAddJob/onCharacterAddOrder/onCharacterRemoveJob
-- are real NOTIFICATION hooks -- they fire whenever ANY code (including the
-- game's own vanilla AI) calls the real addJob/addOrder/removeJob, and do not
-- themselves call anything. That makes a whole new lowest-risk phase possible:
-- OBSERVE what tasks the game assigns real NPCs during normal, unmodified
-- play -- e.g. watch a farmer to see the actual TaskType sequence behind the
-- wheat loop -- with zero calls of our own and therefore zero crash risk.
--
-- FOUR PHASES, RISK-ORDERED (the 01_capability_probe.lua discipline):
--   0. OBSERVE. Register the three notification hooks and log every job/order
--      the game's OWN AI assigns to ANY character. No calls of our own, so it
--      cannot FAULT anything -- but a combat burst (several characters
--      getting addJob/addOrder in the same moment) can still generate enough
--      synchronous log writes to hang the game, found live 2026-08-10 (no
--      new native crash dump afterward -- a hang, not a fault). Rate-limited
--      the same way 28_vanilla_observer.lua's equip/unequip storm was fixed:
--      full detail for the first few firings per event, a count line every
--      50 after that. Projector.counts() gives the running tally regardless.
--   1. READ-ONLY. getPermajobCount()/getPermajob() on the selected character.
--      Zero-arg or int-slot getters only -- no more risk than any other
--      verified getter already in daily use.
--   2. TWO-ARG WRITE. addGoal(TaskType, subject) -- doc and header both
--      claimed 1 int arg; FOUND LIVE 2026-08-12 that is wrong too, same
--      failure class as addJob's missing `subject` below. Real binding
--      requires a second RootObjectBase-typed arg (confirmed via the
--      engine's own argument-error text). Still the safest write to try
--      first -- fewer args and less ambiguity than addJob/addOrder.
--   3. MULTI-ARG WRITE. addJob/addOrder -- HIGHEST RISK. Every variant is
--      wrapped in pcall AND logged BEFORE the call, because pcall does NOT
--      catch a native access violation -- if this crashes the game, the log
--      is the only thing that survives and the last un-matched TRY line
--      names the killer. A crash here is a result, not a failure -- it
--      permanently buys one resolved question either way.
--
-- SAFETY: run phase 2/3 ONLY against a character you do not mind losing --
-- not the player, not a squad member you care about. Phase 0 is safe on
-- anyone, including the player, and is worth leaving running in the
-- background while you play normally.
--
-- 2026-08-12 CORRECTION -- "click a random disposable townsperson" (this
-- section's original advice) does NOT work the way it sounds. getSelectedCharacter()
-- reads PlayerInterface.selectedCharacter, Kenshi's SQUAD ROSTER selection --
-- clicking an arbitrary world NPC does not set it, only selecting one of the
-- player's OWN characters does. Every test run through getSelectedCharacter()
-- targets a squad member, always, no matter what you click on (a tamed
-- animal counts as squad too). There is no known getter for "the NPC I'm
-- currently looking at." Instead: Phase 0's notification hooks receive a
-- live `character` for ANY character the game's own AI acts on, squad or
-- not. startObserve() now stashes the most recent one
-- (Projector.lastObserved() to check who) -- pass `true` as testGoal/
-- testJobOrder's second argument to target THAT character instead of
-- getSelectedCharacter(), for a genuinely independent NPC.
--
--   dofile("mods/KenshiLua/scripts/27_projector_probe.lua")
--   Projector.startObserve()      -- phase 0, always safe, runs in the background
--   Projector.lastObserved()      -- check who Phase 0 most recently captured
--   Projector.stopObserve()       -- turn phase 0 back off
--   Projector.testRead()          -- phase 1, always safe, any character
--   Projector.testGoal("IDLE", true)          -- phase 2, true = target Phase 0's capture
--   Projector.testJobOrder("WANDERER", true)  -- phase 3, HIGHEST RISK, true = target the capture
-- ============================================================================

local TAG = "[PROJECTOR-PROBE] "
local function log(m) print(TAG .. tostring(m)) end

Projector = Projector or {}
pcall(function() _G.Projector = Projector end)

-- RELOAD SAFETY for the phase-0 observer handlers -- same shape as
-- 10_fishing.lua's generation guard: a dofile must not stack a second set of
-- listeners logging everything twice.
if Projector._handlers and type(unregisterHandler) == "function" then
    for _, hid in ipairs(Projector._handlers) do pcall(unregisterHandler, hid) end
end
Projector._handlers = {}

-- Real TaskType ordinals (third_party/KenshiLib/Include/kenshi/Enums.h,
-- 291-entry C enum, 0-indexed -- cross-checked against the header directly,
-- see SPINE.md). IDLE and WANDERER are two of the lowest-consequence tasks
-- in the whole enum: a character told to idle or wander is close to
-- indistinguishable from doing nothing, which is exactly what you want for
-- a first live test of a call that might not even work as documented.
Projector.TASK = {
    NULL_TASK               = 0,
    IDLE                    = 14,
    WANDERER                = 24,
    MOVE_CUS_ORDERED        = 29,
    HOLD_POSITION           = 30,
    PATROL_TOWN             = 36,
    WANDER_TOWN             = 37,
    FOLLOW_PLAYER_ORDER     = 44,
    RECRUIT_AT_JOBCENTER    = 55,
    STAND_STILL             = 62,
    OPERATE_MACHINERY       = 87,
    DELIVER_RESOURCES       = 88,
    COLLECT_OUTPUT_RESOURCE = 92,
    FIND_A_SHOP             = 117,
    SHOPPING                = 118,
    BUY_SHIT                = 119,
    JOB_BUILDER             = 125,
}

-- Reverse lookup (id -> name) so the observer can print a human-readable
-- task name for the ones we bothered to name above. Only 16 of the 291 real
-- TaskType values are named here (the ones relevant to this roadmap); an
-- observed id outside that set just prints as a bare number, which is still
-- useful -- SPINE.md's "OPEN" section has the full enum reference to look it
-- up by hand.
local TASK_NAME = {}
for name, id in pairs(Projector.TASK) do TASK_NAME[id] = name end

-- ---------------------------------------------------------------------------
-- PHASE 0 -- OBSERVE. Zero calls of our own; these three hooks are pure
-- NOTIFICATIONS that fire whenever ANY code (including vanilla AI) invokes
-- the real addJob/addOrder/removeJob. Cannot crash anything it did not
-- already crash on its own -- this only reacts, never calls.
--
-- This is the direct answer to "does wheat farming actually use addJob, and
-- with what TaskType" -- watch a real farmer NPC for a few in-game minutes
-- and read it off the log instead of guessing.
-- ---------------------------------------------------------------------------
local function taskLabel(taskId)
    local n = tonumber(taskId)
    if n and TASK_NAME[n] then return ("%d (%s)"):format(n, TASK_NAME[n]) end
    return tostring(taskId)
end

-- RATE LIMITING. FOUND LIVE 2026-08-10: 28_vanilla_observer.lua's
-- onCharacterEquip/Unequip firing 1510 times in a burst was fixed with
-- exactly this pattern, but the fix was never ported HERE -- a combat burst
-- (multiple characters getting addJob/addOrder in rapid succession as a
-- fight breaks out) produced no new native crash dump afterward, meaning it
-- was very likely a HANG from log-write volume rather than a fault, the
-- same mechanism, just in the sibling file. Same shape as Observer's fix:
-- full detail for the first few firings per event, then a periodic count.
local PROBE_LOG_SAMPLE = 3
local PROBE_LOG_EVERY  = 50
local probeEventCounts = {}

function Projector.counts()
    local keys = {}
    for k in pairs(probeEventCounts) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do log(("%-14s %d"):format(k, probeEventCounts[k])) end
end

local function rateLimited(key, fullLine)
    local n = (probeEventCounts[key] or 0) + 1
    probeEventCounts[key] = n
    if n <= PROBE_LOG_SAMPLE then
        log(fullLine())
    elseif n % PROBE_LOG_EVERY == 0 then
        log(("%s fired %d times so far (full detail for the first %d, a count "
             .. "line every %d after that -- Projector.counts() for the running tally)")
            :format(key, n, PROBE_LOG_SAMPLE, PROBE_LOG_EVERY))
    end
end

function Projector.startObserve()
    -- NOT `not type(x) == "function"` -- `not` binds tighter than `==` in
    -- Lua, so that parses as `(not type(x)) == "function"`, which is always
    -- false (type() never returns nil/false, so `not type(x)` is always
    -- false) regardless of whether registerHandler actually exists. The
    -- exact class of precedence trap test_regressions.lua already pins for
    -- `and`-truncation; caught here before it shipped a second instance.
    if type(registerHandler) ~= "function" then
        log("registerHandler unavailable -- cannot observe")
        return
    end
    if #Projector._handlers > 0 then
        log("already observing -- call Projector.stopObserve() first to restart")
        return
    end

    local function nameOf(character)
        local ok, n = pcall(function() return character:getName() end)
        return ok and n or "?"
    end

    -- CAPTURE. FOUND LIVE 2026-08-12: getSelectedCharacter() reads
    -- PlayerInterface.selectedCharacter, which is Kenshi's SQUAD ROSTER
    -- selection, not a world click-target -- clicking a random townsperson
    -- does not set it, only selecting one of the player's OWN characters
    -- does (BindingsReference.md line ~7237: `selectedCharacter | hand |
    -- RW`, a PlayerInterface property). Every Phase 1/2/3 test run through
    -- getSelectedCharacter() so far -- Dreadnaut, Jakku, even the "bonedog"
    -- -- was therefore very likely still a squad member (a tamed animal
    -- counts as squad), not a genuinely independent NPC; the control-
    -- authority question was never actually settled. Phase 0's notification
    -- hooks receive a live `character` argument for ANY character the
    -- game's own AI acts on, squad or not -- stash the most recent one so
    -- testGoal/testJobOrder can target a real independent NPC by passing
    -- true as their second argument, no squad selection required.
    Projector._lastObserved = Projector._lastObserved or nil
    local function captureLastObserved(character)
        local ok, n = pcall(function() return character:getName() end)
        Projector._lastObserved = { character = character, name = ok and n or "?" }
    end

    local h1 = registerHandler("onCharacterAddJob", function(character, taskType, subject, shift, addDontClear, location)
        captureLastObserved(character)
        rateLimited("addJob", function()
            return ("OBSERVED addJob: %s <- task %s  shift=%s addDontClear=%s")
                :format(nameOf(character), taskLabel(taskType), tostring(shift), tostring(addDontClear))
        end)
    end)
    local h2 = registerHandler("onCharacterAddOrder", function(character, destBuilding, taskType, subject, shift, clear, location)
        captureLastObserved(character)
        rateLimited("addOrder", function()
            return ("OBSERVED addOrder: %s <- task %s  shift=%s clear=%s")
                :format(nameOf(character), taskLabel(taskType), tostring(shift), tostring(clear))
        end)
    end)
    local h3 = registerHandler("onCharacterRemoveJob", function(character, taskType)
        captureLastObserved(character)
        rateLimited("removeJob", function()
            return ("OBSERVED removeJob: %s -x- task %s"):format(nameOf(character), taskLabel(taskType))
        end)
    end)
    for _, h in ipairs({ h1, h2, h3 }) do
        if h then Projector._handlers[#Projector._handlers + 1] = h end
    end
    log(("observing -- %d hook(s) armed. Go watch a farmer, a guard, anyone with a job. Every"):format(#Projector._handlers))
    log("addJob/addOrder/removeJob the game's own AI performs will print here, with real task ids.")
end

-- Projector.lastObserved() -- print who Phase 0 most recently captured, so
-- you can confirm it is a real independent NPC (not one of your own squad)
-- before running testGoal(taskName, true) / testJobOrder(taskName, true)
-- against them.
function Projector.lastObserved()
    if not Projector._lastObserved then
        log("nothing captured yet -- Phase 0 must be running (Projector.startObserve()) and the")
        log("game's own AI must have assigned a job/order to SOMEONE since it started")
        return
    end
    log("last observed: " .. tostring(Projector._lastObserved.name))
end

function Projector.stopObserve()
    if type(unregisterHandler) ~= "function" or #Projector._handlers == 0 then
        log("not observing")
        return
    end
    for _, hid in ipairs(Projector._handlers) do pcall(unregisterHandler, hid) end
    Projector._handlers = {}
    log("observation stopped")
end

-- ---------------------------------------------------------------------------
-- PHASE 1 -- READ ONLY. Safe on any character, including the player.
-- ---------------------------------------------------------------------------
function Projector.testRead()
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then log("select a character first") return end

    log("========== PROJECTOR PHASE 1: READ ==========")
    local okN, name = pcall(function() return c:getName() end)
    log("character: " .. tostring(okN and name or "?"))

    local okC, count = pcall(function() return c:getPermajobCount() end)
    log(("getPermajobCount() -> %s"):format(okC and tostring(count) or ("ERROR " .. tostring(count))))

    if okC and type(count) == "number" and count > 0 then
        for slot = 0, math.min(count - 1, 9) do
            local okS, taskId = pcall(function() return c:getPermajob(slot) end)
            log(("  getPermajob(%d) -> %s"):format(slot, okS and tostring(taskId) or ("ERROR " .. tostring(taskId))))
        end
    end
    log("========== END PHASE 1 ==========")
end

-- ---------------------------------------------------------------------------
-- PHASE 2 -- addGoal(TaskType, subject). FOUND LIVE 2026-08-12:
-- BindingsReference.md documents this as a 1-int-arg call, `addGoal(t)`, and
-- the header agreed -- both wrong, same failure class as addJob's missing
-- `subject` param and onCharacterEquip's swapped arg order. The real binding
-- errors cleanly: "bad argument #2 to 'addGoal' (KenshiLua.RootObjectBase
-- expected, got no value)" -- a second RootObjectBase-typed arg is required.
-- FOUND LIVE 2026-08-12, round 2: both A and B above (this file's own prior
-- guesses) errored too, but with genuinely different, informative text --
-- "expected, got nil" for A (proves nil is rejected in BOTH omitted and
-- explicit form, not just omitted) and "expected, got userdata" for B
-- (proves getHandle() DOES return a real object, just the wrong TYPE -- a
-- `hand`, not a `RootObjectBase`). BindingsReference.md confirms `hand` has
-- its own `getRootObjectBase()` method (`## hand` section) -- the unwrap
-- Character -> getHandle() -> hand -> getRootObjectBase() -> RootObjectBase
-- is the natural next guess, now Variant C below.
--
-- Three variants, best guess first:
--   A. subject = nil (explicit) -- KenshiLua's arg-count check distinguishes
--      "argument omitted" from "argument explicitly nil" (the very error we
--      hit came from OMITTING it entirely), so passing nil explicitly was a
--      different, untested case, not a repeat of the same failure. CONFIRMED
--      WRONG 2026-08-12 -- kept for completeness, not because it might work.
--   B. subject = the character's own handle. CONFIRMED WRONG 2026-08-12 --
--      right idea (mirrors Phase 3's `subject` guess), wrong TYPE.
--   C. subject = the character's own handle's RootObjectBase (the type the
--      engine actually asked for, traced from the BindingsReference.md
--      `hand` class -- highest confidence of the three).
-- ---------------------------------------------------------------------------
-- Shared by testGoal/testJobOrder. useCaptured=true targets whoever Phase 0
-- most recently observed getting a real job/order (a genuinely independent
-- NPC, squad or not -- see the capture note above startObserve()); omitted
-- or false falls back to getSelectedCharacter(), which -- FOUND LIVE
-- 2026-08-12 -- can ONLY ever return one of the player's own squad, never
-- an arbitrary world NPC, regardless of what you click on.
local function resolveTestTarget(useCaptured)
    if useCaptured then
        if not (Projector._lastObserved and Projector._lastObserved.character) then
            log("no captured character yet -- run Projector.startObserve() and wait for the")
            log("game's own AI to assign SOMEONE a job, or check Projector.lastObserved()")
            return nil
        end
        return Projector._lastObserved.character
    end
    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then
        log("select a character first (this will be one of YOUR squad -- pass true as the")
        log("second argument instead to target Phase 0's last captured independent NPC)")
        return nil
    end
    return c
end

function Projector.testGoal(taskName, useCaptured)
    taskName = taskName or "IDLE"
    local taskId = Projector.TASK[taskName]
    if not taskId then log("unknown task: " .. tostring(taskName)) return end

    local c = resolveTestTarget(useCaptured)
    if not c then return end
    local okN, name = pcall(function() return c:getName() end)
    log(("========== PROJECTOR PHASE 2: addGoal(%s=%d) on %s =========="):format(taskName, taskId, tostring(okN and name or "?")))

    local okHand, selfHand = pcall(function() return c:getHandle() end)
    local okRoot, selfRoot = false, nil
    if okHand and selfHand then
        okRoot, selfRoot = pcall(function() return selfHand:getRootObjectBase() end)
    end
    local variants = {
        { label = "A (subject=nil, explicit)",
          call = function() c:addGoal(taskId, nil) end },
        { label = "B (subject=own handle)",
          call = function() c:addGoal(taskId, okHand and selfHand or nil) end },
        { label = "C (subject=own handle:getRootObjectBase())",
          call = function() c:addGoal(taskId, okRoot and selfRoot or nil) end },
    }

    for _, v in ipairs(variants) do
        log("TRY " .. v.label .. ": c:addGoal(" .. taskId .. ", ...)")   -- LOG-AS-CURSOR: printed BEFORE the call
        local okCall, err = pcall(v.call)
        log(("addGoal variant -> %s"):format(okCall and "returned (no error)" or ("ERROR " .. tostring(err))))
        if okCall then
            log("Returned cleanly. STOP HERE.")
            log("Now WATCH the character for the next several seconds: did behavior change at all?")
            log("========== END PHASE 2 (stopped after first clean variant) ==========")
            return
        end
    end

    log("========== END PHASE 2 ==========")
    log("All variants errored (not crashed). Record the ERROR text verbatim.")
end

-- ---------------------------------------------------------------------------
-- PHASE 3 -- addJob / addOrder. HIGHEST RISK. Four variants, best evidence
-- first:
--   A. FOUND LIVE 2026-08-12, round 2 -- the FIRST live Phase 3 attempt used
--      subject=RootObjectBase (the addGoal fix) and errored:
--      "bad argument #2 to 'addJob' (KenshiLua.RootObject expected, got
--      userdata)" -- addJob wants a DIFFERENT type than addGoal.
--      RootObject and RootObjectBase are genuinely separate classes in
--      BindingsReference.md (`## RootObject` at one header, `## RootObjectBase`
--      at another), not the same type under two names. The `hand` class
--      that already solved addGoal turns out to have BOTH unwrap methods
--      sitting right next to each other: `getRootObjectBase()` (addGoal) AND
--      `getRootObject()` (addJob's actual ask, per the error text). Highest
--      confidence untried shape:
--      addJob(task, subject:RootObject, shift, addDontClear, location)
--   B. The CallbacksReference.md dispatcher shape with the raw hand
--      (CONFIRMED WRONG live -- "RootObject expected, got userdata" --
--      kept for completeness, not because it might work).
--   C. The C++ AITaskSystem.h header (a plausible OTHER overload/wrapper
--      layer): addJob(task, subject:hand, location, shift)
--   D. The BindingsReference.md doc shape (CONFIRMED WRONG live --
--      "RootObject expected, got boolean", the doc's missing `subject`
--      param means some OTHER arg lands in that slot instead -- kept for
--      completeness).
-- Stops at the first variant that does not error. Each attempt is logged
-- BEFORE it runs -- pcall does not catch a native access violation, so the
-- log is the only thing that survives a crash and names the killer.
-- ---------------------------------------------------------------------------
function Projector.testJobOrder(taskName, useCaptured)
    taskName = taskName or "WANDERER"
    local taskId = Projector.TASK[taskName]
    if not taskId then log("unknown task: " .. tostring(taskName)) return end

    local c = resolveTestTarget(useCaptured)
    if not c then return end
    local okN, name = pcall(function() return c:getName() end)
    log(("========== PROJECTOR PHASE 3: addJob/addOrder(%s=%d) on %s =========="):format(taskName, taskId, tostring(okN and name or "?")))

    local okPos, pos = pcall(function() return c:getPosition() end)
    if not okPos then log("cannot read own position, aborting -- location arg would be a pure guess") return end

    -- selfHand may end up nil if getHandle fails; the `subject` argument's
    -- real meaning for a targetless task like WANDERER/IDLE is unclear, so
    -- nil is a legitimate first guess, not a mistake.
    local okHand, selfHand = pcall(function() return c:getHandle() end)
    local subject = okHand and selfHand or nil

    local okRootObj, selfRootObj = false, nil
    if okHand and selfHand then
        okRootObj, selfRootObj = pcall(function() return selfHand:getRootObject() end)
    end
    local rootObjSubject = okRootObj and selfRootObj or nil

    local variants = {
        { label = "A (dispatcher shape, subject=RootObject unwrap -- try first, matches addJob's own error text)",
          call = function() c:addJob(taskId, rootObjSubject, false, false, pos) end },
        { label = "B (dispatcher shape, subject=raw hand -- CONFIRMED WRONG live, kept for completeness)",
          call = function() c:addJob(taskId, subject, false, false, pos) end },
        { label = "C (AITaskSystem.h header shape)",
          call = function() c:addJob(taskId, subject, pos, false) end },
        { label = "D (BindingsReference.md doc shape -- CONFIRMED WRONG live, kept for completeness)",
          call = function() c:addJob(taskId, false, false, pos) end },
    }

    for _, v in ipairs(variants) do
        log("TRY " .. v.label)   -- LOG-AS-CURSOR: printed BEFORE the call
        local okV, errV = pcall(v.call)
        log(("addJob variant -> %s"):format(okV and "returned (no error)" or ("ERROR " .. tostring(errV))))
        if okV then
            log("Returned cleanly. STOP HERE -- do not try further variants against this character.")
            log("Watch the character now: did behavior actually change?")
            log("========== END PHASE 3 (stopped after first clean variant) ==========")
            return
        end
    end

    log("========== END PHASE 3 ==========")
    log("All variants errored (not crashed). Record the ERROR text verbatim --")
    log("KenshiLua's argument-error strings are how every other signature in this")
    log("project's history got solved (KENSHI-ENGINE-NOTES.md section 1).")
end

log("27_projector_probe loaded.")
log("  Projector.startObserve()               -- phase 0, always safe, any character, runs passively")
log("  Projector.lastObserved()               -- who Phase 0 most recently captured (see below)")
log("  Projector.stopObserve()                -- turn phase 0 back off")
log("  Projector.testRead()                   -- phase 1, always safe, any character")
log("  Projector.testGoal(taskName, true)      -- phase 2, true = target Phase 0's captured NPC")
log("  Projector.testJobOrder(taskName, true)  -- phase 3, HIGHEST RISK, true = target the capture")
log("CAUTION: getSelectedCharacter() (used when the 2nd arg above is omitted/false) is Kenshi's")
log("SQUAD ROSTER selection, not a world click-target -- it can only ever return one of your own")
log("characters, no matter what you click on. Pass true to target Phase 0's captured character")
log("instead for a genuinely independent NPC.")
log("task names: IDLE, WANDERER, MOVE_CUS_ORDERED, HOLD_POSITION, PATROL_TOWN, WANDER_TOWN,")
log("            FOLLOW_PLAYER_ORDER, RECRUIT_AT_JOBCENTER, STAND_STILL, OPERATE_MACHINERY,")
log("            DELIVER_RESOURCES, COLLECT_OUTPUT_RESOURCE, FIND_A_SHOP, SHOPPING, BUY_SHIT, JOB_BUILDER")
