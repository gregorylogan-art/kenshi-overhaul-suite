# Test plan — run these in order

**Do not play-test blind.** Each test below has a command, an expected result,
and what it proves. Random outcomes (an 80% junk roll) are never the way to
verify a code path — the commands make each one deterministic.

Reload after a deploy (do **not** also restart):
```lua
dofile("mods/KenshiLua/scripts/init/10_fishing.lua")
```

---

## T1 — Is everything wired?  *(2 seconds, no fishing)*

```lua
Fishing.status()
```

**Expect:**
```
selected character : <name>
can fish now       : false  (on land -- wade into the shallows | ...)
junk granting      : true
skill model wired  : true
xp granting        : true
fish item in use   : Small Fish      <- or "(unresolved)" until first catch
live odds          : nothing 5.0%  junk 80.0%  fish 15.0%
```

**Proves:** scripts loaded, skill model connected, junk enabled, odds correct.
**Report:** any line reading `false` or `nil` that should not.

---

## T2 — Does the outcome table match the design?  *(1 second)*

```lua
Fishing.testRoll(300)
```

**Expect:** roughly `nothing 5%  junk 80%  fish 15%` (±3%).

**Proves:** the 5/80/15 split is real. This previously read **95% fish** because
the junk band fell through — a bug invisible to casual play.
**Report:** the printed percentages.

---

## T3 — THE SAFETY TEST: does junk break the inventory?  *(the important one)*

⚠️ **Use an expendable character.**

```lua
Fishing.testGrant("Straw Hat")
Fishing.testGrant("Rag Loincloth")
Fishing.testGrant("Wooden Bowl")
Fishing.testGrant("Cup")
```

Then **open the inventory and the stats screen.**

**Expect:** each prints `OK`, items appear, both screens open normally.

**Proves / disproves** issue #21. The theory: items minted when there is no room
were orphaned against the inventory handle and broke the GUI's layout. Food is
1×1 and always places; clothing is multi-cell and fails. A `hasRoomForItem()`
check now runs *before* minting.

**Report:** whether the inventory still opens. If it breaks, say which item was
last granted — that names the culprit.

---

## T4 — Does XP actually land?  *(no grinding)*

```lua
Fishing.testXp(200)
```

Then open the character's **Skills** tab.

**Expect:** log shows `labouring 1.000->1.043` style before/after deltas, and the
tab moves for Labouring / Swimming / Precision Shooting / Perception.

**Proves:** `xpStat_eventBased` reaches the real skill. Kenshi XP is far too slow
to confirm this by playing.
**Report:** whether the numbers move in the log *and* in the tab.

---

## T5 — Does skill change the odds?  *(1 second, no grinding)*

```lua
Fishing.simulate()
```

**Expect:**
```
prec=0   swim=0   labour=0   | nothing 5.0%  junk 80.0%  fish 15.0%  cast 5.00s
prec=100 swim=100 labour=100 | nothing 3.0%  junk 35.0%  fish 62.0%  cast 4.00s
```

**Proves:** the class-fantasy curve. The model was previously **inert** — XP rose
and changed nothing.

---

## T6 — The real loop  *(finally, actual fishing)*

Wade into shallow water (`waterLevel` 1–2), hold still, press **G**.

**Expect:** one `cast!` line, then after 5s a `CAUGHT` line and an item.

**Report:** one cast per press? Item in inventory? If a cast breaks, paste the
`moved N units (tolerance M)` line so the standstill radius can be tuned from
your numbers.

---

## T7 — WSM contract  *(no character or world needed)*

```lua
WSM.selftest()
```

**Expect:** `--- SELFTEST: 9 passed, 0 failed ---`

**Proves:** mutate contract, re-entrancy refusal, monotonic time, catch-up
stopping at failure, snapshot round-trip.

---

## How to report

For each test, one line is enough: **T3 OK** / **T3 FAILED — inventory would not
open after Rag Loincloth**. Paste log lines only when something fails; the
structured reader (`tools/readlog.py`) pulls the rest.
