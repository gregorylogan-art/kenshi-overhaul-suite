-- ============================================================================
-- PROJECTOR CAPABILITY PROBE  (manual only -- lives in scripts/, NOT scripts/init/)
--
-- Answers the single biggest open question blocking #28/#33/#34 and everything
-- downstream of them (#25, #46, #49, #50): can Lua actually drive an NPC
-- through a job/task, or is "verified hooks" in those issues just a doc claim
-- that was never run? See docs/architecture/SPINE.md's "OPEN: NPC job/task
-- assignment" section for the full static-analysis writeup this probe tests
-- -- including the finding that the bindings doc and the real C++ header
-- (AITaskSystem.h) DISAGREE on addJob/addOrder's argument shape.
--
-- THREE PHASES, RISK-ORDERED (the 01_capability_probe.lua discipline):
--   1. READ-ONLY. getPermajobCount()/getPermajob() on the selected character.
--      Zero-arg or int-slot getters only -- no more risk than any other
--      verified getter already in daily use.
--   2. SINGLE-ARG WRITE. addGoal(TaskType) -- 1 int, and the doc and header
--      AGREE on this one's shape, so it is the safest write to try first.
--   3. MULTI-ARG WRITE. addJob/addOrder -- HIGHEST RISK. Every variant is
--      wrapped in pcall AND logged BEFORE the call, because pcall does NOT
--      catch a native access violation -- if this crashes the game, the log
--      is the only thing that survives and the last un-matched TRY line
--      names the killer. A crash here is a result, not a failure -- it
--      permanently buys one resolved question either way.
--
-- SAFETY: run phase 2/3 ONLY against a character you do not mind losing --
-- not the player, not a squad member you care about. Click a random,
-- disposable townsperson before calling these.
--
--   dofile("mods/KenshiLua/scripts/27_projector_probe.lua")
--   Projector.testRead()          -- phase 1, always safe, any character
--   Projector.testGoal("IDLE")    -- phase 2, select a DISPOSABLE NPC first
--   Projector.testJobOrder("WANDERER")  -- phase 3, HIGHEST RISK, disposable NPC first
-- ============================================================================

local TAG = "[PROJECTOR-PROBE] "
local function log(m) print(TAG .. tostring(m)) end

Projector = Projector or {}
pcall(function() _G.Projector = Projector end)

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
-- PHASE 2 -- addGoal(TaskType). 1 int arg; doc and header AGREE on this
-- signature (unlike addJob/addOrder below), so this is the safest write to
-- try first. If this does nothing observable, that is a clean, uninformative
-- result -- not a crash, and still worth knowing.
-- ---------------------------------------------------------------------------
function Projector.testGoal(taskName)
    taskName = taskName or "IDLE"
    local taskId = Projector.TASK[taskName]
    if not taskId then log("unknown task: " .. tostring(taskName)) return end

    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then log("select a DISPOSABLE (non-player, non-squad) character first") return end
    local okN, name = pcall(function() return c:getName() end)
    log(("========== PROJECTOR PHASE 2: addGoal(%s=%d) on %s =========="):format(taskName, taskId, tostring(okN and name or "?")))

    log("TRY: c:addGoal(" .. taskId .. ")")   -- LOG-AS-CURSOR: printed BEFORE the call
    local okCall, err = pcall(function() c:addGoal(taskId) end)
    log(("addGoal(%d) -> %s"):format(taskId, okCall and "returned (no error)" or ("ERROR " .. tostring(err))))
    log("If the game is still running and this line printed, the call did not hard-crash.")
    log("Now WATCH the character for the next several seconds: did behavior change at all?")
    log("========== END PHASE 2 ==========")
end

-- ---------------------------------------------------------------------------
-- PHASE 3 -- addJob / addOrder. HIGHEST RISK: the bindings doc and the real
-- C++ header disagree on argument shape (see SPINE.md). Tries the HEADER's
-- shape first (it is the primary source; the doc has 29+ confirmed wrong
-- signatures elsewhere in this project's own history), then the DOC's
-- shape, stopping at the first variant that does not error. Each attempt is
-- logged BEFORE it runs.
-- ---------------------------------------------------------------------------
function Projector.testJobOrder(taskName)
    taskName = taskName or "WANDERER"
    local taskId = Projector.TASK[taskName]
    if not taskId then log("unknown task: " .. tostring(taskName)) return end

    local ok, c = pcall(function() return getSelectedCharacter() end)
    if not ok or not c then log("select a DISPOSABLE (non-player, non-squad) character first") return end
    local okN, name = pcall(function() return c:getName() end)
    log(("========== PROJECTOR PHASE 3: addJob/addOrder(%s=%d) on %s =========="):format(taskName, taskId, tostring(okN and name or "?")))

    local okPos, pos = pcall(function() return c:getPosition() end)
    if not okPos then log("cannot read own position, aborting -- location arg would be a pure guess") return end

    -- selfHand may end up nil if getHandle fails; the `subject` argument's
    -- real meaning for a targetless task like WANDERER/IDLE is unclear from
    -- the header alone, so nil is a legitimate first guess, not a mistake.
    local okHand, selfHand = pcall(function() return c:getHandle() end)

    -- Variant A: the C++ HEADER's shape -- addJob(t, subject:hand, location, shift)
    log("TRY A (header shape): c:addJob(" .. taskId .. ", <selfHandle>, <ownPos>, false)")
    local okA, errA = pcall(function() c:addJob(taskId, okHand and selfHand or nil, pos, false) end)
    log(("addJob variant A -> %s"):format(okA and "returned (no error)" or ("ERROR " .. tostring(errA))))
    if okA then
        log("Variant A returned cleanly. STOP HERE -- do not try further variants against this character.")
        log("Watch the character now: did behavior actually change?")
        log("========== END PHASE 3 (stopped after first clean variant) ==========")
        return
    end

    -- Variant B: the DOC's shape -- addJob(t, shift, addDontClear, location)
    log("TRY B (doc shape): c:addJob(" .. taskId .. ", false, false, <ownPos>)")
    local okB, errB = pcall(function() c:addJob(taskId, false, false, pos) end)
    log(("addJob variant B -> %s"):format(okB and "returned (no error)" or ("ERROR " .. tostring(errB))))
    if okB then
        log("Variant B returned cleanly. STOP HERE.")
        log("Watch the character now: did behavior actually change?")
    end

    log("========== END PHASE 3 ==========")
    if not okA and not okB then
        log("Both variants errored (not crashed). addJob's real shape is neither guess tried")
        log("here -- record the ERROR text verbatim. KenshiLua's argument-error strings are")
        log("how every other signature in this project's history got solved (see")
        log("KENSHI-ENGINE-NOTES.md section 1 -- 'Docs argument columns are unreliable').")
    end
end

log("27_projector_probe loaded.")
log("  Projector.testRead()               -- phase 1, always safe, any character")
log("  Projector.testGoal(taskName)       -- phase 2, select a DISPOSABLE character first")
log("  Projector.testJobOrder(taskName)   -- phase 3, HIGHEST RISK, disposable character first")
log("  task names: IDLE, WANDERER, MOVE_CUS_ORDERED, HOLD_POSITION, PATROL_TOWN, WANDER_TOWN,")
log("              FOLLOW_PLAYER_ORDER, RECRUIT_AT_JOBCENTER, STAND_STILL, OPERATE_MACHINERY,")
log("              DELIVER_RESOURCES, COLLECT_OUTPUT_RESOURCE, FIND_A_SHOP, SHOPPING, BUY_SHIT, JOB_BUILDER")
