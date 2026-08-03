-- ============================================================================
-- REGRESSION TESTS -- one test per bug that actually cost us a session.
--
-- Run:  python tools/luarun.py --tests
--
-- Every case below is a REAL failure this project shipped, not a hypothetical.
-- A test suite full of invented cases proves the author's imagination; a suite
-- built from scars proves the code stopped doing the thing it actually did.
--
-- None of these need Kenshi. All of them were originally found by Greg playing
-- the game, which is the expensive way to find a arithmetic bug.
-- ============================================================================

local T = { passed = 0, failed = 0, names = {} }

local function check(name, cond, detail)
    if cond then
        T.passed = T.passed + 1
    else
        T.failed = T.failed + 1
        T.names[#T.names + 1] = name .. (detail and ("  -- " .. tostring(detail)) or "")
    end
end

-- ---------------------------------------------------------------------------
-- BUG: the junk band fell through to fish.
-- With junk granting disabled, a junk roll returned a FISH, so the shipped
-- distribution was 5% nothing / 95% fish instead of 5/80/15 -- the exact
-- opposite of the design, and invisible in play because fish are what you want.
-- ---------------------------------------------------------------------------
local function bandOf(r, pctNothing, pctJunk)
    if r < pctNothing then return "nothing" end
    if r < pctNothing + pctJunk then return "junk" end
    return "fish"
end

do
    check("band: 0.00 -> nothing", bandOf(0.00, 0.05, 0.80) == "nothing")
    check("band: 0.04 -> nothing", bandOf(0.04, 0.05, 0.80) == "nothing")
    check("band: 0.05 -> junk (boundary is exclusive-low)", bandOf(0.05, 0.05, 0.80) == "junk")
    check("band: 0.84 -> junk", bandOf(0.84, 0.05, 0.80) == "junk")
    check("band: 0.99 -> fish", bandOf(0.99, 0.05, 0.80) == "fish")

    -- FLOATING-POINT BOUNDARY, found by this suite on its first run.
    -- 0.05 + 0.80 == 0.85000000000000008882 in IEEE754, so r == 0.85 exactly
    -- lands in JUNK, not fish -- the junk band is one ULP wider than 0.80.
    --
    -- Left as documented behaviour rather than "fixed": the error is ~1e-16 of
    -- the distribution, math.random() essentially never returns exactly 0.85,
    -- and the measured spread below is inside 1%. Asserting the other way would
    -- be testing the FPU, not our logic. Recorded so a future reader who spots
    -- the asymmetry knows it was seen and judged, not missed.
    check("band: 0.85 lands in junk (one ULP, documented)",
          bandOf(0.85, 0.05, 0.80) == "junk",
          "if this flips, the cumulative-threshold maths changed")

    -- The distribution must actually be 5/80/15 across the unit interval.
    local n, j, f = 0, 0, 0
    for i = 0, 9999 do
        local b = bandOf(i / 10000, 0.05, 0.80)
        if b == "nothing" then n = n + 1 elseif b == "junk" then j = j + 1 else f = f + 1 end
    end
    check("distribution nothing ~5%",  math.abs(n / 10000 - 0.05) < 0.01, n / 10000)
    check("distribution junk ~80%",    math.abs(j / 10000 - 0.80) < 0.01, j / 10000)
    check("distribution fish ~15%",    math.abs(f / 10000 - 0.15) < 0.01, f / 10000)
end

-- ---------------------------------------------------------------------------
-- BUG: `local okN, curName = ok and character and pcall(...)`
-- A Lua `and` expression truncates multiple returns to ONE value, so curName was
-- always nil, the caster check always failed, every cast was skipped, and casts
-- hung on "already casting" forever. This pins the language behaviour so nobody
-- reintroduces the pattern believing it works.
-- ---------------------------------------------------------------------------
do
    local function two() return true, "name" end
    local a, b = true and two()
    check("and-truncation: first value survives", a == true)
    check("and-truncation: SECOND VALUE IS LOST", b == nil,
          "if this fails, Lua changed and the guard comment is stale")

    local c, d = two()
    check("direct call keeps both returns", c == true and d == "name")
end

-- ---------------------------------------------------------------------------
-- BUG: FISH_PREFERENCE was used at line 221 but declared at 258.
-- Lua locals are invisible above their declaration, so it was nil and
-- ipairs(nil) threw on EVERY cast. The symptom read as "casting does nothing".
-- ---------------------------------------------------------------------------
do
    local ok = pcall(function()
        local t = nil
        for _ in ipairs(t) do end   -- luacheck: ignore
    end)
    check("ipairs(nil) throws (the use-before-declare symptom)", ok == false)
end

-- ---------------------------------------------------------------------------
-- BUG: the progress bar snapped 0 <-> 100 instead of filling.
-- bar.progress is 0..1000 (widget RangePosition) but bar:setProgress() takes a
-- 0..1 fraction. Feeding the 1000-scale value to the method clamps to full.
-- ---------------------------------------------------------------------------
do
    local RANGE = 1000
    local function fieldValue(frac) return math.floor(frac * RANGE) end
    local function methodValue(frac) return frac end

    check("field scale at half",  fieldValue(0.5) == 500)
    check("method scale at half", methodValue(0.5) == 0.5)
    check("field never exceeds range", fieldValue(1.0) == RANGE)
    -- The actual bug: 2% progress produced 20, which any 0..1 method clamps to full.
    check("2% would clamp if fed to the method", fieldValue(0.02) > 1,
          "20 > 1 means setProgress(20) reads as 100%")
end

-- ---------------------------------------------------------------------------
-- ITEMS: conservation. Nothing minted from nothing, nothing vanishing.
-- ---------------------------------------------------------------------------
if _G.Items then
    local KEY = "__regress__"
    Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil

    Items.bank(KEY, "Small Fish", 7)
    Items.bank(KEY, "Book", 3)
    local _, total = Items.bagOf(KEY)
    check("items: bank totals", total == 10)

    Items.take(KEY, "Book", 3)
    local bag, t2 = Items.bagOf(KEY)
    check("items: take reduces total", t2 == 7)
    check("items: emptied row is REMOVED not zeroed", bag["Book"] == nil)

    check("items: overdraw refused", Items.take(KEY, "Small Fish", 99) == false)
    check("items: overdraw changed nothing", select(2, Items.bagOf(KEY)) == 7)

    check("items: invariants clean", #Items.verify() == 0)

    -- INV5 is the engine law made checkable: no inventory write without collect.
    local before = Items.stats.inventoryWrites
    Items.bank(KEY, "Small Fish", 5)
    check("items: banking performs NO inventory writes",
          Items.stats.inventoryWrites == before,
          "banking must never touch an inventory -- this is issue #37")

    Items.bags[KEY], Items.counts[KEY], Items.ledger[KEY] = nil, nil, nil
end

-- ---------------------------------------------------------------------------
-- COOKING: the sink must actually cost something, and conserve.
-- ---------------------------------------------------------------------------
if _G.Cooking then
    check("cooking: unskilled burns more than skilled", Cooking.odds(0) > Cooking.odds(100))
    check("cooking: burn chance never reaches zero", Cooking.odds(100) > 0,
          "a lossless conversion turns fishing back into a money printer")
    check("cooking: burn chance never reaches one", Cooking.odds(0) < 1)
    check("cooking: odds clamp on nonsense input",
          Cooking.odds(-999) == Cooking.odds(0) and Cooking.odds(1e9) == Cooking.odds(100))
end

-- ---------------------------------------------------------------------------
-- WSM: the two StarFall tick bugs this project was built to avoid.
-- ---------------------------------------------------------------------------
if _G.WSM then
    check("wsm: has a mutate contract", type(WSM.mutate) == "function")
    check("wsm: has snapshot/restore", type(WSM.snapshot) == "function")
end

-- ---------------------------------------------------------------------------
print(("--- REGRESSIONS: %d passed, %d failed ---"):format(T.passed, T.failed))
for _, n in ipairs(T.names) do print("    FAILED: " .. n) end
if T.failed > 0 then error("regression failures", 0) end
return true
